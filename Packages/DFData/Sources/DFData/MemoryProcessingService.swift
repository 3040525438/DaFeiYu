import Foundation
import GRDB
import DFCore

// MARK: - 输入 / 输出

/// 一轮对话的原文与来源锚点。
public struct MemoryTurnSource: Sendable, Equatable {
    public var conversationID: String
    public var userMessageID: String
    public var assistantMessageID: String?
    /// 本轮可定位的原文（用户 + 助手），证据摘录必须能在这里找到
    public var text: String
    public var at: Int64

    public init(
        conversationID: String,
        userMessageID: String,
        assistantMessageID: String? = nil,
        text: String,
        at: Int64
    ) {
        self.conversationID = conversationID
        self.userMessageID = userMessageID
        self.assistantMessageID = assistantMessageID
        self.text = text
        self.at = at
    }
}

public struct MemoryIngestReport: Sendable, Equatable {
    public var writtenMemoryIDs: [String]
    public var proposalIDs: [String]
    /// 命中既有去重键、只补来源的条数
    public var mergedSourceCount: Int
    public var episodeIDs: [String]
    public var rejections: [MemoryScreenRejection]
    public var droppedByBudget: Int

    public init(
        writtenMemoryIDs: [String] = [],
        proposalIDs: [String] = [],
        mergedSourceCount: Int = 0,
        episodeIDs: [String] = [],
        rejections: [MemoryScreenRejection] = [],
        droppedByBudget: Int = 0
    ) {
        self.writtenMemoryIDs = writtenMemoryIDs
        self.proposalIDs = proposalIDs
        self.mergedSourceCount = mergedSourceCount
        self.episodeIDs = episodeIDs
        self.rejections = rejections
        self.droppedByBudget = droppedByBudget
    }
}

public struct MemoryConsolidationReport: Sendable, Equatable {
    public var scope: MemoryScope
    public var mergedGroups: Int
    public var superseded: Int
    public var disputedFacts: Int
    public var archived: Int
    public var indexRebuilt: Bool

    public init(
        scope: MemoryScope,
        mergedGroups: Int = 0,
        superseded: Int = 0,
        disputedFacts: Int = 0,
        archived: Int = 0,
        indexRebuilt: Bool = false
    ) {
        self.scope = scope
        self.mergedGroups = mergedGroups
        self.superseded = superseded
        self.disputedFacts = disputedFacts
        self.archived = archived
        self.indexRebuilt = indexRebuilt
    }
}

public struct ReflectionDraft: Sendable, Equatable {
    public var scope: MemoryScope
    public var kind: String
    public var subject: String
    public var conclusions: [ReflectionConclusion]
    /// 允许被引用的素材 ID（记忆 / 情景 / 变化事件）
    public var availableRefs: [String]
    public var confidence: Double
    /// 稳定结论是否沉淀成自身记忆
    public var depositStableSelfMemories: Bool

    public init(
        scope: MemoryScope = .selfScope,
        kind: String = "daily",
        subject: String = "",
        conclusions: [ReflectionConclusion],
        availableRefs: [String],
        confidence: Double = 0.6,
        depositStableSelfMemories: Bool = true
    ) {
        self.scope = scope
        self.kind = kind
        self.subject = subject
        self.conclusions = conclusions
        self.availableRefs = availableRefs
        self.confidence = confidence
        self.depositStableSelfMemories = depositStableSelfMemories
    }
}

public struct ReflectionOutcome: Sendable, Equatable {
    public var reflectionIDs: [String]
    public var depositedMemoryIDs: [String]
    public var proposalIDs: [String]
    public var rejectedCount: Int

    public init(
        reflectionIDs: [String] = [],
        depositedMemoryIDs: [String] = [],
        proposalIDs: [String] = [],
        rejectedCount: Int = 0
    ) {
        self.reflectionIDs = reflectionIDs
        self.depositedMemoryIDs = depositedMemoryIDs
        self.proposalIDs = proposalIDs
        self.rejectedCount = rejectedCount
    }
}

public struct MemoryGraphResult: Sendable, Equatable {
    public var nodeID: String
    public var entityEdges: Int
    public var episodeEdges: Int

    public init(nodeID: String, entityEdges: Int = 0, episodeEdges: Int = 0) {
        self.nodeID = nodeID
        self.entityEdges = entityEdges
        self.episodeEdges = episodeEdges
    }
}

public enum MemoryProcessingError: Error, Equatable, CustomStringConvertible {
    case emptySource
    case memoryNotFound(String)

    public var description: String {
        switch self {
        case .emptySource: return "本轮原文为空，无法校验证据"
        case .memoryNotFound(let id): return "记忆不存在：\(id)"
        }
    }
}

// MARK: - 记忆加工服务（L1 → L7）

/// 承载 L1–L7 的写入闭环：
/// - L1 只读，`messages` 是唯一真相；
/// - L2 情景、L3 语义、L4 程序、L5 反思写入 `memories` / `episodes` / `reflections`；
/// - L6 图谱由 `buildGraph` 派生；
/// - L7 工作记忆只做运行时装包与快照，**永不**直接写入长期记忆。
///
/// 硬约束：
/// - 证据无法在本轮原文定位的候选一律丢弃（防编造）；
/// - 重要度高或涉及关系/底线时只写 `proposals`，不自动生效；
/// - 反思结论必须引用真实素材，核心人格只能提案。
public final class MemoryProcessingService: @unchecked Sendable {
    /// L7 快照 TTL：24 小时
    public static let workingMemoryTTLMillis: Int64 = 24 * 60 * 60 * 1000
    /// 整理去重阈值
    public static let consolidationSimilarity: Double = 0.90

    private let database: AppDatabase
    private let repository: GRDBMemoryRepository
    private let policy: MemoryExtractionPolicy
    private let reflectionPolicy: ReflectionPolicy
    private let now: @Sendable () -> Int64

    public init(
        database: AppDatabase,
        policy: MemoryExtractionPolicy = .default,
        reflectionPolicy: ReflectionPolicy = .default,
        now: @escaping @Sendable () -> Int64 = { Clock.nowMillis() }
    ) {
        self.database = database
        self.repository = GRDBMemoryRepository(database: database)
        self.policy = policy
        self.reflectionPolicy = reflectionPolicy
        self.now = now
    }

    // MARK: - L2/L3/L4/L5 抽取写入

    @discardableResult
    public func ingest(
        _ candidates: [MemoryCandidate],
        from turn: MemoryTurnSource,
        remainingBudget: Int? = nil
    ) async throws -> MemoryIngestReport {
        let sourceText = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else { throw MemoryProcessingError.emptySource }

        let screened = policy.screen(
            candidates,
            sourceText: sourceText,
            remainingBudget: remainingBudget
        )

        var written: [String] = []
        var proposals: [String] = []
        var merged = 0
        var episodic: [(scope: MemoryScope, memoryID: String, candidate: MemoryCandidate)] = []

        for candidate in screened.accepted {
            let key = candidate.dedupeKey ?? policy.normalizedDedupeKey(for: candidate)
            if try await existingMemoryID(dedupeKey: key) != nil {
                merged += 1
            }

            switch policy.route(for: candidate) {
            case .confirm:
                proposals.append(try await insertMemoryProposal(candidate, dedupeKey: key, turn: turn))
            case .direct:
                let record = try await repository.insert(
                    draft(for: candidate, dedupeKey: key, turn: turn),
                    at: turn.at
                )
                try await recordImportance(record.id, score: candidate.importance, at: turn.at)
                written.append(record.id)
                if candidate.layer == .episodic {
                    episodic.append((candidate.scope, record.id, candidate))
                }
            }
        }

        let episodeIDs = try await createEpisodes(episodic, turn: turn)

        return MemoryIngestReport(
            writtenMemoryIDs: written,
            proposalIDs: proposals,
            mergedSourceCount: merged,
            episodeIDs: episodeIDs,
            rejections: screened.rejections,
            droppedByBudget: screened.droppedByBudget
        )
    }

    // MARK: - 整理（去重 / 冲突 / 归档 / 索引 / 统计）

    @discardableResult
    public func consolidate(scope: MemoryScope) async throws -> MemoryConsolidationReport {
        let timestamp = now()

        let outcome = try await database.write { db -> (merged: Int, superseded: Int, disputed: Int, archived: Int, ftsMismatch: Bool) in
            let items = try Self.loadConsolidationItems(db, scope: scope)
            var merged = 0
            var superseded = 0
            var archived = 0

            // 阶段 1：去重合并（同 scope + layer + category 内）
            let groups = MemoryConsolidationPlanner.duplicateGroups(
                items,
                threshold: Self.consolidationSimilarity
            ) { lhs, rhs in
                self.policy.similarity(lhs, rhs)
            }
            for group in groups {
                guard group.count > 1, let survivor = group.first else { continue }
                merged += 1
                for loser in group.dropFirst() {
                    try db.execute(
                        sql: "UPDATE memories SET status = 'superseded', updated_at = ? WHERE id = ?",
                        arguments: [timestamp, loser]
                    )
                    try db.execute(
                        sql: """
                        INSERT INTO memory_links
                            (id, from_memory_id, to_memory_id, relation, note, confidence, created_at)
                        VALUES (?, ?, ?, 'supersedes', '整理合并：保留信息量最大的一条', 0.9, ?)
                        ON CONFLICT(from_memory_id, to_memory_id, relation) DO NOTHING
                        """,
                        arguments: [UUID().uuidString, survivor, loser, timestamp]
                    )
                    try db.execute(sql: "DELETE FROM memory_fts WHERE memory_id = ?", arguments: [loser])
                    superseded += 1
                }
            }

            // 阶段 2：事实冲突（同实体同属性、值不同）
            let disputed = try Self.resolveFactConflicts(db, scope: scope, at: timestamp)

            // 阶段 3：冷记忆归档（>180 天未召回且 salience < 0.3）
            for item in items where !groups.contains(where: { $0.contains(item.id) }) {
                guard MemoryConsolidationPlanner.shouldArchive(item, now: timestamp) else { continue }
                try db.execute(
                    sql: "UPDATE memories SET archived_at = ?, updated_at = ? WHERE id = ? AND archived_at IS NULL",
                    arguments: [timestamp, timestamp, item.id]
                )
                archived += 1
            }

            // 阶段 4：索引一致性（不一致由外层重建）
            let ftsCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM memory_fts") ?? 0
            let expected = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM memories WHERE deleted_at IS NULL AND status <> 'superseded'"
            ) ?? 0
            let mismatch = ftsCount != expected

            // 阶段 5：统计快照（按层计数）
            try Self.writeStats(db, scope: scope, at: timestamp)
            let report = MemoryConsolidationReport(
                scope: scope,
                mergedGroups: merged,
                superseded: superseded,
                disputedFacts: disputed,
                archived: archived,
                indexRebuilt: mismatch
            )
            try Self.writeReportSnapshot(db, report: report, at: timestamp)

            return (merged, superseded, disputed, archived, mismatch)
        }

        var rebuilt = false
        if outcome.ftsMismatch {
            try await repository.rebuildIndex()
            rebuilt = true
        }

        return MemoryConsolidationReport(
            scope: scope,
            mergedGroups: outcome.merged,
            superseded: outcome.superseded,
            disputedFacts: outcome.disputed,
            archived: outcome.archived,
            indexRebuilt: rebuilt
        )
    }

    // MARK: - 反思（L5）

    @discardableResult
    public func reflect(_ draft: ReflectionDraft) async throws -> ReflectionOutcome {
        let validation = reflectionPolicy.validate(
            draft.conclusions,
            availableRefs: Set(draft.availableRefs)
        )
        let timestamp = now()

        var reflectionIDs: [String] = []
        var deposited: [String] = []
        var proposals: [String] = []

        for conclusion in validation.accepted {
            let reflectionID = UUID().uuidString
            try await database.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO reflections
                        (id, scope, kind, subject, content, conclusion, input_refs_json,
                         confidence, epistemic_status, source_kind, status, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'model_reflection', 'active', ?, ?)
                    """,
                    arguments: [
                        reflectionID, draft.scope.rawValue, draft.kind, draft.subject,
                        conclusion.content, conclusion.conclusion,
                        Self.jsonArray(conclusion.evidenceRefs), min(max(draft.confidence, 0), 1),
                        conclusion.epistemicStatus, timestamp, timestamp
                    ]
                )
            }
            reflectionIDs.append(reflectionID)

            if conclusion.affectsCorePersona {
                // 核心人格只能提案，不自动生效
                proposals.append(
                    try await insertPersonaProposal(conclusion, draft: draft, at: timestamp)
                )
                continue
            }

            guard draft.depositStableSelfMemories, conclusion.stable else { continue }
            let candidate = MemoryCandidate(
                scope: draft.scope,
                layer: .reflective,
                category: "reflection",
                title: conclusion.conclusion.isEmpty ? "自我反思" : conclusion.conclusion,
                content: conclusion.content,
                evidenceQuote: conclusion.content,
                importance: draft.confidence,
                confidence: draft.confidence,
                epistemicStatus: conclusion.epistemicStatus,
                sourceKind: "model_reflection"
            )
            let sources = conclusion.evidenceRefs.map {
                MemorySourceRef(sourceType: "reflection_material", sourceID: $0, excerpt: "", at: timestamp)
            }
            let record = try await repository.insert(
                MemoryDraft(
                    type: MemoryLayer.reflective.rawValue,
                    title: candidate.title,
                    content: candidate.content,
                    scope: draft.scope,
                    layer: MemoryLayer.reflective.rawValue,
                    category: "reflection",
                    sourceKind: "model_reflection",
                    epistemicStatus: conclusion.epistemicStatus,
                    importance: Self.importanceLabel(draft.confidence),
                    confidence: draft.confidence,
                    salience: draft.confidence,
                    dedupeKey: policy.normalizedDedupeKey(for: candidate),
                    sources: sources
                ),
                at: timestamp
            )
            deposited.append(record.id)
        }

        return ReflectionOutcome(
            reflectionIDs: reflectionIDs,
            depositedMemoryIDs: deposited,
            proposalIDs: proposals,
            rejectedCount: validation.rejected.count
        )
    }

    // MARK: - L6 图谱派生

    @discardableResult
    public func buildGraph(memoryID: String, at millis: Int64? = nil) async throws -> MemoryGraphResult {
        let timestamp = millis ?? now()
        return try await database.write { db in
            guard let memory = try Row.fetchOne(
                db,
                sql: "SELECT id, title, scope, layer FROM memories WHERE id = ? AND deleted_at IS NULL",
                arguments: [memoryID]
            ) else {
                throw MemoryProcessingError.memoryNotFound(memoryID)
            }
            let title = try memory.decode(String.self, forColumn: "title")
            let scopeValue = try memory.decode(String.self, forColumn: "scope")
            let layerValue = try memory.decode(String.self, forColumn: "layer")
            let propsJSON = "{\"scope\":\"\(scopeValue)\",\"layer\":\"\(layerValue)\"}"

            let nodeID = try Self.upsertNode(
                db,
                kind: "memory",
                refType: "memory",
                refID: memoryID,
                label: title,
                propsJSON: propsJSON,
                at: timestamp
            )

            var entityEdges = 0
            let facts = try Row.fetchAll(
                db,
                sql: "SELECT id, entity_id, confidence, source_kind FROM entity_facts WHERE memory_id = ?",
                arguments: [memoryID]
            )
            for fact in facts {
                let entityID = try fact.decode(String.self, forColumn: "entity_id")
                guard let entity = try Row.fetchOne(
                    db,
                    sql: "SELECT name FROM entities WHERE id = ?",
                    arguments: [entityID]
                ) else { continue }
                let entityNode = try Self.upsertNode(
                    db,
                    kind: "entity",
                    refType: "entity",
                    refID: entityID,
                    label: try entity.decode(String.self, forColumn: "name"),
                    propsJSON: "{}",
                    at: timestamp
                )
                let inserted = try Self.insertEdge(
                    db,
                    from: nodeID,
                    to: entityNode,
                    relation: "about",
                    confidence: Double.fromDatabaseValue(fact["confidence"]) ?? 0.6,
                    sourceKind: String.fromDatabaseValue(fact["source_kind"]) ?? "real_interaction",
                    sourceRef: try fact.decode(String.self, forColumn: "id"),
                    at: timestamp
                )
                if inserted { entityEdges += 1 }
            }

            var episodeEdges = 0
            let episodes = try Row.fetchAll(
                db,
                sql: """
                SELECT e.id, e.title FROM episode_memories em
                JOIN episodes e ON e.id = em.episode_id
                WHERE em.memory_id = ?
                """,
                arguments: [memoryID]
            )
            for episode in episodes {
                let episodeID = try episode.decode(String.self, forColumn: "id")
                let episodeNode = try Self.upsertNode(
                    db,
                    kind: "episode",
                    refType: "episode",
                    refID: episodeID,
                    label: try episode.decode(String.self, forColumn: "title"),
                    propsJSON: "{}",
                    at: timestamp
                )
                let inserted = try Self.insertEdge(
                    db,
                    from: nodeID,
                    to: episodeNode,
                    relation: "part_of",
                    confidence: 0.8,
                    sourceKind: "real_interaction",
                    sourceRef: memoryID,
                    at: timestamp
                )
                if inserted { episodeEdges += 1 }
            }

            return MemoryGraphResult(nodeID: nodeID, entityEdges: entityEdges, episodeEdges: episodeEdges)
        }
    }

    // MARK: - L7 工作记忆快照

    public func saveWorkingMemory(_ package: WorkingMemoryPackage) async throws {
        let encoder = JSONEncoder()
        let payload = String(data: try encoder.encode(package), encoding: .utf8) ?? "{}"
        let expiresAt = package.builtAt + Self.workingMemoryTTLMillis
        let messageCount = package.items.filter { $0.kind == .recentTurn }.count

        try await database.write { db in
            // 过期即删；同一会话只保留最新一份
            try db.execute(sql: "DELETE FROM working_memory_snapshots WHERE expires_at < ?", arguments: [package.builtAt])
            try db.execute(
                sql: "DELETE FROM working_memory_snapshots WHERE conversation_id = ?",
                arguments: [package.conversationID]
            )
            try db.execute(
                sql: """
                INSERT INTO working_memory_snapshots
                    (id, conversation_id, built_at, expires_at, token_estimate, message_count, payload_json)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    UUID().uuidString, package.conversationID, package.builtAt, expiresAt,
                    package.estimatedTokens, messageCount, payload
                ]
            )
        }
    }

    public func workingMemory(conversationID: String, at millis: Int64? = nil) async throws -> WorkingMemoryPackage? {
        let timestamp = millis ?? now()
        return try await database.dbQueue.read { db in
            guard let payload = try String.fetchOne(
                db,
                sql: """
                SELECT payload_json FROM working_memory_snapshots
                WHERE conversation_id = ? AND expires_at >= ?
                ORDER BY built_at DESC LIMIT 1
                """,
                arguments: [conversationID, timestamp]
            ), let data = payload.data(using: .utf8) else {
                return nil
            }
            return try JSONDecoder().decode(WorkingMemoryPackage.self, from: data)
        }
    }

    @discardableResult
    public func purgeExpiredWorkingMemory(at millis: Int64? = nil) async throws -> Int {
        let timestamp = millis ?? now()
        return try await database.write { db in
            try db.execute(sql: "DELETE FROM working_memory_snapshots WHERE expires_at < ?", arguments: [timestamp])
            return db.changesCount
        }
    }

    // MARK: - 内部：写入辅助

    private func existingMemoryID(dedupeKey: String) async throws -> String? {
        try await database.dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT id FROM memories WHERE dedupe_key = ? AND deleted_at IS NULL",
                arguments: [dedupeKey]
            )
        }
    }

    private func draft(for candidate: MemoryCandidate, dedupeKey: String, turn: MemoryTurnSource) -> MemoryDraft {
        var sources = [
            MemorySourceRef(
                sourceType: "message",
                sourceID: turn.userMessageID,
                excerpt: candidate.evidenceQuote,
                at: turn.at
            )
        ]
        if let assistantID = turn.assistantMessageID, !assistantID.isEmpty {
            sources.append(
                MemorySourceRef(
                    sourceType: "message",
                    sourceID: assistantID,
                    excerpt: candidate.evidenceQuote,
                    at: turn.at
                )
            )
        }
        return MemoryDraft(
            type: candidate.layer.rawValue,
            title: candidate.title,
            content: candidate.content,
            scope: candidate.scope,
            layer: candidate.layer.rawValue,
            category: MemoryGovernance.normalizeCategory(candidate.category),
            sourceKind: candidate.sourceKind,
            epistemicStatus: candidate.epistemicStatus,
            importance: Self.importanceLabel(candidate.importance),
            confidence: candidate.confidence,
            salience: candidate.importance,
            dedupeKey: dedupeKey,
            sources: sources
        )
    }

    /// 初始重要度直接落库（不做"变更留痕"：留痕只用于后续修改）
    private func recordImportance(_ memoryID: String, score: Double, at millis: Int64) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                UPDATE memories
                SET importance_score = ?, importance_source = 'extraction',
                    importance_source_at = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [min(max(score, 0), 1), millis, millis, memoryID]
            )
        }
    }

    private func insertMemoryProposal(
        _ candidate: MemoryCandidate,
        dedupeKey: String,
        turn: MemoryTurnSource
    ) async throws -> String {
        let id = UUID().uuidString
        let payload = MemoryProposalPayload(
            scope: candidate.scope.rawValue,
            layer: candidate.layer.rawValue,
            category: MemoryGovernance.normalizeCategory(candidate.category),
            title: candidate.title,
            content: candidate.content,
            evidenceQuote: candidate.evidenceQuote,
            importance: candidate.importance,
            confidence: candidate.confidence,
            epistemicStatus: candidate.epistemicStatus,
            sourceKind: candidate.sourceKind,
            conversationID: turn.conversationID,
            userMessageID: turn.userMessageID,
            assistantMessageID: turn.assistantMessageID,
            dedupeKey: dedupeKey
        )
        let payloadJSON = String(data: try JSONEncoder().encode(payload), encoding: .utf8) ?? "{}"
        let risk = candidate.importance >= 0.9 ? "high" : "medium"
        let reason = "重要度 \(String(format: "%.2f", candidate.importance)) 或涉及关系/归属待确认，需用户确认后写入"

        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO proposals
                    (id, kind, payload_json, reason, evidence_json, status, created_at, resolved_at,
                     resolution_note, scope, risk, expires_at, decided_by)
                VALUES (?, 'memory', ?, ?, ?, 'pending', ?, NULL, NULL, ?, ?, NULL, NULL)
                """,
                arguments: [
                    id, payloadJSON, reason, Self.jsonArray([candidate.evidenceQuote]),
                    turn.at, candidate.scope.rawValue, risk
                ]
            )
        }
        return id
    }

    private func insertPersonaProposal(
        _ conclusion: ReflectionConclusion,
        draft: ReflectionDraft,
        at millis: Int64
    ) async throws -> String {
        let id = UUID().uuidString
        let payload: [String: String] = [
            "conclusion": conclusion.conclusion,
            "content": conclusion.content,
            "scope": draft.scope.rawValue,
            "kind": draft.kind,
            "epistemic_status": conclusion.epistemicStatus
        ]
        let payloadJSON = String(data: try JSONEncoder().encode(payload), encoding: .utf8) ?? "{}"

        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO proposals
                    (id, kind, payload_json, reason, evidence_json, status, created_at, resolved_at,
                     resolution_note, scope, risk, expires_at, decided_by)
                VALUES (?, 'persona', ?, '反思触及核心人格，只能提案不能自动生效', ?, 'pending', ?, NULL, NULL, 'self', 'high', NULL, NULL)
                """,
                arguments: [id, payloadJSON, Self.jsonArray(conclusion.evidenceRefs), millis]
            )
        }
        return id
    }

    private func createEpisodes(
        _ items: [(scope: MemoryScope, memoryID: String, candidate: MemoryCandidate)],
        turn: MemoryTurnSource
    ) async throws -> [String] {
        guard !items.isEmpty else { return [] }

        var grouped: [MemoryScope: [(memoryID: String, candidate: MemoryCandidate)]] = [:]
        for item in items {
            grouped[item.scope, default: []].append((item.memoryID, item.candidate))
        }
        let buckets = grouped

        return try await database.write { db in
            var ids: [String] = []
            for (scope, entries) in buckets {
                let id = UUID().uuidString
                let title = entries.first?.candidate.title ?? "未命名事件"
                let summary = entries.map { $0.candidate.content }.joined(separator: "；")
                let importance = entries.map { $0.candidate.importance }.max() ?? 0.5
                let confidence = entries.map { $0.candidate.confidence }.reduce(0, +) / Double(max(entries.count, 1))

                try db.execute(
                    sql: """
                    INSERT INTO episodes
                        (id, scope, title, summary, started_at, ended_at, time_precision,
                         participants_json, emotion_json, importance, confidence, source_kind,
                         status, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, 'day', '[]', '{}', ?, ?, 'real_interaction', 'active', ?, ?)
                    """,
                    arguments: [
                        id, scope.rawValue, title, summary, turn.at, turn.at,
                        importance, confidence, turn.at, turn.at
                    ]
                )
                for entry in entries {
                    try db.execute(
                        sql: """
                        INSERT INTO episode_memories (episode_id, memory_id, role)
                        VALUES (?, ?, 'detail')
                        ON CONFLICT(episode_id, memory_id) DO NOTHING
                        """,
                        arguments: [id, entry.memoryID]
                    )
                }
                ids.append(id)
            }
            return ids.sorted()
        }
    }

    // MARK: - 内部：整理辅助

    private static func loadConsolidationItems(_ db: Database, scope: MemoryScope) throws -> [MemoryConsolidationItem] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, scope, layer, category, title, content, salience, last_recalled_at, first_seen_at
            FROM memories
            WHERE scope = ? AND status = 'active' AND deleted_at IS NULL AND archived_at IS NULL
            ORDER BY id
            """,
            arguments: [scope.rawValue]
        )
        return rows.compactMap { row -> MemoryConsolidationItem? in
            guard let memoryScope = MemoryScope(rawValue: String.fromDatabaseValue(row["scope"]) ?? "") else {
                return nil
            }
            return MemoryConsolidationItem(
                id: String.fromDatabaseValue(row["id"]) ?? "",
                scope: memoryScope,
                layer: String.fromDatabaseValue(row["layer"]) ?? "semantic",
                category: String.fromDatabaseValue(row["category"]) ?? "fact",
                title: String.fromDatabaseValue(row["title"]) ?? "",
                content: String.fromDatabaseValue(row["content"]) ?? "",
                salience: Double.fromDatabaseValue(row["salience"]) ?? 0.5,
                lastRecalledAt: Int64.fromDatabaseValue(row["last_recalled_at"]),
                firstSeenAt: Int64.fromDatabaseValue(row["first_seen_at"]) ?? 0
            )
        }
        .filter { !$0.id.isEmpty }
    }

    /// 同实体同属性、值不同：能判定时间变化则前后并存，否则双方 disputed 并建变化事件。
    private static func resolveFactConflicts(_ db: Database, scope: MemoryScope, at millis: Int64) throws -> Int {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT f.id, f.entity_id, f.attribute, f.value, f.valid_from, f.valid_to
            FROM entity_facts f
            JOIN entities e ON e.id = f.entity_id
            WHERE f.status = 'active'
            """
        )
        var snapshots: [MemoryFactSnapshot] = []
        for row in rows {
            snapshots.append(
                MemoryFactSnapshot(
                    id: String.fromDatabaseValue(row["id"]) ?? "",
                    subject: String.fromDatabaseValue(row["entity_id"]) ?? "",
                    attribute: String.fromDatabaseValue(row["attribute"]) ?? "",
                    value: String.fromDatabaseValue(row["value"]) ?? "",
                    validFrom: Int64.fromDatabaseValue(row["valid_from"]),
                    validTo: Int64.fromDatabaseValue(row["valid_to"])
                )
            )
        }

        var disputed = 0
        for index in snapshots.indices {
            for other in snapshots.index(after: index)..<snapshots.count {
                let lhs = snapshots[index]
                let rhs = snapshots[other]
                switch MemoryConflictDetector.conflict(between: lhs, and: rhs) {
                case .none:
                    continue
                case .timeChange:
                    // 早的一条补 valid_to，两条并存
                    let older, newer: MemoryFactSnapshot
                    if (lhs.validFrom ?? 0) <= (rhs.validFrom ?? 0) {
                        older = lhs
                        newer = rhs
                    } else {
                        older = rhs
                        newer = lhs
                    }
                    guard older.validTo == nil, let boundary = newer.validFrom else { continue }
                    try db.execute(
                        sql: "UPDATE entity_facts SET valid_to = ?, updated_at = ? WHERE id = ?",
                        arguments: [boundary, millis, older.id]
                    )
                case .dispute:
                    try db.execute(
                        sql: "UPDATE entity_facts SET status = 'disputed', updated_at = ? WHERE id IN (?, ?)",
                        arguments: [millis, lhs.id, rhs.id]
                    )
                    let existing = try Bool.fetchOne(
                        db,
                        sql: """
                        SELECT 1 FROM change_events
                        WHERE scope = ? AND subject_type = 'entity_fact' AND subject_ref = ?
                          AND dimension = ? AND status = 'open'
                        """,
                        arguments: [scope.rawValue, lhs.id, "fact:\(lhs.attribute)"]
                    )
                    if existing == nil {
                        try db.execute(
                            sql: """
                            INSERT INTO change_events
                                (id, scope, subject_type, subject_ref, dimension,
                                 from_value, to_value, detected_at, confidence, evidence_json, status)
                            VALUES (?, ?, 'entity_fact', ?, ?, ?, ?, ?, 0.5, ?, 'open')
                            """,
                            arguments: [
                                UUID().uuidString, scope.rawValue, lhs.id, "fact:\(lhs.attribute)",
                                lhs.value, rhs.value, millis, jsonArray([lhs.id, rhs.id])
                            ]
                        )
                    }
                    disputed += 1
                }
            }
        }
        return disputed
    }

    private static func writeStats(_ db: Database, scope: MemoryScope, at millis: Int64) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT layer, COUNT(*) AS total FROM memories
            WHERE scope = ? AND deleted_at IS NULL AND status <> 'superseded'
            GROUP BY layer
            """,
            arguments: [scope.rawValue]
        )
        var stats: [String: Int] = [:]
        for row in rows {
            stats[String.fromDatabaseValue(row["layer"]) ?? "unknown"] = Int.fromDatabaseValue(row["total"]) ?? 0
        }
        let json = String(data: try JSONEncoder().encode(stats), encoding: .utf8) ?? "{}"
        try writeSetting(db, key: "memory.stats.\(scope.rawValue)", value: json)
    }

    private static func writeReportSnapshot(_ db: Database, report: MemoryConsolidationReport, at millis: Int64) throws {
        let json = """
        {"scope":"\(report.scope.rawValue)","mergedGroups":\(report.mergedGroups),\
        "superseded":\(report.superseded),"disputedFacts":\(report.disputedFacts),\
        "archived":\(report.archived),"indexRebuilt":\(report.indexRebuilt),"at":\(millis)}
        """
        try writeSetting(db, key: "memory.consolidation.last.\(report.scope.rawValue)", value: json)
    }

    private static func writeSetting(_ db: Database, key: String, value: String) throws {
        try db.execute(
            sql: """
            INSERT INTO settings (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [key, value]
        )
    }

    // MARK: - 内部：图谱辅助

    private static func upsertNode(
        _ db: Database,
        kind: String,
        refType: String,
        refID: String,
        label: String,
        propsJSON: String,
        at millis: Int64
    ) throws -> String {
        if let existing = try String.fetchOne(
            db,
            sql: "SELECT id FROM kg_nodes WHERE ref_type = ? AND ref_id = ?",
            arguments: [refType, refID]
        ) {
            try db.execute(
                sql: "UPDATE kg_nodes SET label = ?, kind = ?, props_json = ? WHERE id = ?",
                arguments: [label, kind, propsJSON, existing]
            )
            return existing
        }
        let id = UUID().uuidString
        try db.execute(
            sql: """
            INSERT INTO kg_nodes (id, kind, label, ref_type, ref_id, props_json, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [id, kind, label, refType, refID, propsJSON, millis]
        )
        return id
    }

    private static func insertEdge(
        _ db: Database,
        from: String,
        to: String,
        relation: String,
        confidence: Double,
        sourceKind: String,
        sourceRef: String?,
        at millis: Int64
    ) throws -> Bool {
        guard from != to else { return false }
        let existing = try Bool.fetchOne(
            db,
            sql: "SELECT 1 FROM kg_edges WHERE from_node_id = ? AND to_node_id = ? AND relation = ?",
            arguments: [from, to, relation]
        )
        guard existing == nil else { return false }
        try db.execute(
            sql: """
            INSERT INTO kg_edges
                (id, from_node_id, to_node_id, relation, valid_from, valid_to,
                 confidence, source_kind, source_ref, props_json, created_at)
            VALUES (?, ?, ?, ?, NULL, NULL, ?, ?, ?, '{}', ?)
            """,
            arguments: [UUID().uuidString, from, to, relation, confidence, sourceKind, sourceRef, millis]
        )
        return true
    }

    // MARK: - 内部：通用

    private static func importanceLabel(_ score: Double) -> String {
        if score >= 0.8 { return "high" }
        if score >= 0.5 { return "normal" }
        return "low"
    }

    private static func jsonArray(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    private struct MemoryProposalPayload: Codable {
        var scope: String
        var layer: String
        var category: String
        var title: String
        var content: String
        var evidenceQuote: String
        var importance: Double
        var confidence: Double
        var epistemicStatus: String
        var sourceKind: String
        var conversationID: String
        var userMessageID: String
        var assistantMessageID: String?
        var dedupeKey: String
    }
}

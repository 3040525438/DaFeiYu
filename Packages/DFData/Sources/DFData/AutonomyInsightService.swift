import Foundation
import GRDB
import DFCore

/// 自主洞察服务（D62）：主动回顾近期经历、历史记忆关联、发现值得记录的经历、
/// 识别用户观点变化、主动提出记忆回顾 / 修正建议。
///
/// 边界（硬规则）：
/// - 生成必须基于真实上下文；上下文为空时直接拒绝，不凭空编造；
/// - 模型输出必须是严格 JSON；证据必须逐字来自上下文，不在上下文中的证据一律丢弃；
/// - 关联 / 修正类洞察的目标记忆必须真实存在于 `memories` 且为 active，否则丢弃；
/// - **只产出待用户确认的提案**：本服务不写 `memories`、不改人格、不动关系；
/// - 用户确认（approve）只把提案状态推进到 approved，实际写入由既有记忆 / 人格服务完成；
/// - 同类同摘要的待确认提案不重复堆积。
public final class AutonomyInsightService: @unchecked Sendable {
    /// 上下文：调用方提供逐字片段，服务不做二次摘要
    public struct Context: Sendable {
        /// 关联会话（可为空：纯后台整理）
        public var conversationID: String?
        /// 最近几条真实对话（形如「用户：…」「大肥鱼：…」）
        public var recentTurns: [String]
        /// 候选记忆（来自 L1–L7 记忆层）
        public var candidateMemories: [String]
        /// 用户反馈提示（如"用户对 suggestion 表示不感兴趣"）
        public var feedbackHints: [String]

        public init(
            conversationID: String? = nil,
            recentTurns: [String],
            candidateMemories: [String] = [],
            feedbackHints: [String] = []
        ) {
            self.conversationID = conversationID
            self.recentTurns = recentTurns
            self.candidateMemories = candidateMemories
            self.feedbackHints = feedbackHints
        }

        /// 供证据比对使用的完整上下文
        public var contextText: String {
            (recentTurns + candidateMemories + feedbackHints).joined(separator: "\n")
        }
    }

    /// 一条待确认的洞察提案（对应 `proposals` 表 kind = `autonomy_insight`）
    public struct Proposal: Sendable, Equatable, Identifiable {
        public var id: String
        public var kind: ReflectionInsightKind
        public var summary: String
        public var evidence: [String]
        public var confidence: Double
        public var targetMemoryID: String?
        /// 恒由类型决定，模型无法改写
        public var requiresUserConfirmation: Bool
        /// pending / approved / rejected
        public var status: String
        public var createdAt: Int64
        public var resolvedAt: Int64?
        public var resolutionNote: String?
    }

    /// 一次生成的结果：解析失败时 `insights` / `proposals` 为空，`failure` 说明原因。
    public struct Outcome: Sendable {
        public var insights: [ReflectionInsight]
        public var proposals: [Proposal]
        public var failure: ReflectionInsightParseFailure?
        public var usage: Usage?

        public var isStrict: Bool { failure == nil }
    }

    public enum InsightError: Error, Equatable, CustomStringConvertible {
        case emptyContext
        case proposalNotFound(String)
        case proposalResolved(String)

        public var description: String {
            switch self {
            case .emptyContext:
                return "缺少可用的上下文，不能凭空生成自主洞察"
            case .proposalNotFound(let id):
                return "洞察提案不存在：\(id)"
            case .proposalResolved(let status):
                return "洞察提案已处理（\(status)），不能重复操作"
            }
        }
    }

    /// 提案在 `proposals.kind` 中的取值
    public static let proposalKind = "autonomy_insight"

    private let database: AppDatabase
    private let clock: AutonomyClock

    public init(database: AppDatabase, clock: AutonomyClock = .system) {
        self.database = database
        self.clock = clock
    }

    // MARK: - 生成

    /// 调模型生成一次洞察，只落"待用户确认"的提案。
    public func generate(
        context: Context,
        provider: ChatModelProvider,
        model: String,
        maxTokens: Int = 480
    ) async throws -> Outcome {
        let contextText = context.contextText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contextText.isEmpty else { throw InsightError.emptyContext }

        let request = ChatRequest(
            model: model,
            systemPrompt: Self.systemPrompt,
            messages: [ChatTurn(role: .user, text: Self.userPrompt(context: context))],
            temperature: 0.4,
            maxTokens: maxTokens
        )

        var raw = ""
        var usage: Usage?
        for try await delta in provider.stream(request) {
            if Task.isCancelled { throw DFError.cancelled }
            switch delta {
            case .text(let piece):
                raw += piece
            case .usage(let value):
                usage = value
            case .finished:
                break
            }
        }

        let parsed = ReflectionInsightParser.parse(raw)
        guard parsed.failure == nil else {
            return Outcome(insights: [], proposals: [], failure: parsed.failure, usage: usage)
        }

        // 证据逐字校验 → 去重 → 截断
        let cleaned = ReflectionInsightPolicy.sanitizeBatch(parsed.insights, contextText: contextText)
        // 目标记忆必须真实存在，避免提案指向不存在的记忆
        let verified = try await verifyTargets(cleaned)
        let proposals = try await persist(verified)
        return Outcome(insights: verified, proposals: proposals, failure: nil, usage: usage)
    }

    // MARK: - 读取与确认

    /// 待确认提案（按创建时间倒序）
    public func pending(limit: Int = 20) async throws -> [Proposal] {
        try await database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM proposals
                 WHERE kind = ? AND status = 'pending'
                 ORDER BY created_at DESC
                 LIMIT ?
                """,
                arguments: [Self.proposalKind, max(1, limit)]
            ).compactMap { Self.decodeProposal($0) }
        }
    }

    /// 全部提案（含已处理，便于审计）
    public func proposals(limit: Int = 50) async throws -> [Proposal] {
        try await database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM proposals
                 WHERE kind = ?
                 ORDER BY created_at DESC
                 LIMIT ?
                """,
                arguments: [Self.proposalKind, max(1, limit)]
            ).compactMap { Self.decodeProposal($0) }
        }
    }

    /// 用户确认：只推进状态，**不写记忆、不改人格**。
    @discardableResult
    public func approve(id: String) async throws -> Proposal {
        try await resolve(id: id, status: "approved", note: nil)
    }

    /// 用户驳回
    public func reject(id: String, note: String) async throws {
        _ = try await resolve(id: id, status: "rejected", note: note)
    }

    // MARK: - 内部

    private func resolve(id: String, status: String, note: String?) async throws -> Proposal {
        try await database.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM proposals WHERE id = ? AND kind = ?",
                arguments: [id, Self.proposalKind]
            ) else {
                throw InsightError.proposalNotFound(id)
            }
            let current = try row.decode(String.self, forColumn: "status")
            guard current == "pending" else {
                throw InsightError.proposalResolved(current)
            }
            try db.execute(
                sql: """
                UPDATE proposals
                   SET status = ?, resolved_at = ?, resolution_note = ?
                 WHERE id = ?
                """,
                arguments: [status, self.clock.now(), note, id]
            )
            guard let updated = try Row.fetchOne(
                db,
                sql: "SELECT * FROM proposals WHERE id = ?",
                arguments: [id]
            ), let proposal = Self.decodeProposal(updated) else {
                throw InsightError.proposalNotFound(id)
            }
            return proposal
        }
    }

    /// 目标记忆不存在（或已非 active）的洞察一律丢弃。
    private func verifyTargets(_ insights: [ReflectionInsight]) async throws -> [ReflectionInsight] {
        var result: [ReflectionInsight] = []
        for insight in insights {
            guard let target = insight.targetMemoryID else {
                result.append(insight)
                continue
            }
            let exists = try await database.dbQueue.read { db in
                (try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM memories WHERE id = ? AND status = 'active'",
                    arguments: [target]
                ) ?? 0) == 1
            }
            if exists { result.append(insight) }
        }
        return result
    }

    /// 落库为待确认提案；同类同摘要的 pending 提案不重复堆积。
    private func persist(_ insights: [ReflectionInsight]) async throws -> [Proposal] {
        guard !insights.isEmpty else { return [] }
        return try await database.write { db in
            var existingKeys = Set<String>()
            let pendingRows = try Row.fetchAll(
                db,
                sql: "SELECT payload_json FROM proposals WHERE kind = ? AND status = 'pending'",
                arguments: [Self.proposalKind]
            )
            for row in pendingRows {
                if let text = try? row.decode(String.self, forColumn: "payload_json"),
                   let dict = Self.decodePayload(text),
                   let kind = dict.kind {
                    existingKeys.insert("\(kind.rawValue)|\(ReflectionInsightPolicy.normalized(dict.summary))")
                }
            }

            let at = self.clock.now()
            var created: [Proposal] = []
            for insight in insights {
                let key = "\(insight.kind.rawValue)|\(ReflectionInsightPolicy.normalized(insight.summary))"
                guard !existingKeys.contains(key) else { continue }
                existingKeys.insert(key)

                let id = UUID().uuidString
                try db.execute(
                    sql: """
                    INSERT INTO proposals
                        (id, kind, payload_json, reason, evidence_json, status, created_at)
                    VALUES (?, ?, ?, ?, ?, 'pending', ?)
                    """,
                    arguments: [
                        id,
                        Self.proposalKind,
                        Self.encodePayload(insight),
                        "\(insight.kind.displayName)：\(insight.summary)",
                        Self.encodeEvidence(insight.evidence),
                        at
                    ]
                )
                created.append(
                    Proposal(
                        id: id,
                        kind: insight.kind,
                        summary: insight.summary,
                        evidence: insight.evidence,
                        confidence: insight.confidence,
                        targetMemoryID: insight.targetMemoryID,
                        requiresUserConfirmation: insight.requiresUserConfirmation,
                        status: "pending",
                        createdAt: at,
                        resolvedAt: nil,
                        resolutionNote: nil
                    )
                )
            }
            return created
        }
    }

    // MARK: - 编解码

    private struct Payload {
        var kind: ReflectionInsightKind?
        var summary: String
    }

    private static func decodePayload(_ text: String) -> Payload? {
        guard let data = text.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let summary = dict["summary"] as? String else {
            return nil
        }
        let kind = (dict["kind"] as? String).flatMap { ReflectionInsightKind(rawValue: $0) }
        return Payload(kind: kind, summary: summary)
    }

    private static func encodePayload(_ insight: ReflectionInsight) -> String {
        var dict: [String: Any] = [
            "kind": insight.kind.rawValue,
            "summary": insight.summary,
            "evidence": insight.evidence,
            "confidence": insight.confidence,
            "requires_user_confirmation": insight.requiresUserConfirmation
        ]
        if let target = insight.targetMemoryID {
            dict["target_memory_id"] = target
        }
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func encodeEvidence(_ evidence: [String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: evidence, options: []))
            ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeProposal(_ row: Row) -> Proposal? {
        guard let payloadText = try? row.decode(String.self, forColumn: "payload_json"),
              let data = payloadText.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kindRaw = dict["kind"] as? String,
              let kind = ReflectionInsightKind(rawValue: kindRaw),
              let summary = dict["summary"] as? String,
              let confidence = (dict["confidence"] as? NSNumber)?.doubleValue else {
            return nil
        }
        let evidence = (dict["evidence"] as? [Any])?.compactMap { $0 as? String } ?? []
        return Proposal(
            id: (try? row.decode(String.self, forColumn: "id")) ?? "",
            kind: kind,
            summary: summary,
            evidence: evidence,
            confidence: confidence,
            targetMemoryID: dict["target_memory_id"] as? String,
            requiresUserConfirmation: kind.requiresUserConfirmation,
            status: (try? row.decode(String.self, forColumn: "status")) ?? "pending",
            createdAt: (try? row.decode(Int64.self, forColumn: "created_at")) ?? 0,
            resolvedAt: optionalInt64(row, "resolved_at"),
            resolutionNote: optionalString(row, "resolution_note")
        )
    }

    private static func optionalString(_ row: Row, _ column: String) -> String? {
        guard row.hasColumn(column) else { return nil }
        return String.fromDatabaseValue(row[column])
    }

    private static func optionalInt64(_ row: Row, _ column: String) -> Int64? {
        guard row.hasColumn(column) else { return nil }
        return Int64.fromDatabaseValue(row[column])
    }

    // MARK: - 提示词

    /// 严格 Schema 的系统提示词：键集固定，不允许自由发挥。
    static let systemPrompt = """
    你是"大肥鱼"的记忆整理模块。请只输出一个 JSON 对象，不要输出任何解释、前后缀或 Markdown。

    JSON 结构（键必须完全一致，不能增删改名）：
    {"insights":[{"kind":"...","summary":"...","evidence":["..."],"confidence":0.0,"target_memory_id":null}]}

    约束：
    1. kind 只能取：recall_recent（回顾近期经历）、memory_link（历史记忆关联）、
       worth_recording（发现值得记录的经历）、stance_change（识别用户观点变化）、
       correction_proposal（记忆修正建议）。
    2. summary 为一句中文结论，不超过 80 字，不得编造上下文没有的事实。
    3. evidence 必须从给定上下文中逐字摘抄，最多 4 条，每条不超过 100 字；
       找不到逐字证据时不要输出该条洞察。
    4. confidence 为 0 到 1 的小数，表示你对这条判断的把握。
    5. memory_link 与 correction_proposal 必须给出 target_memory_id，且只能取上下文中出现过的记忆 id；
       其他类型固定写 null。
    6. 没有任何值得说的洞察时，输出 {"insights":[]}。
    7. 你没有权限写入记忆或修改人格：所有洞察都只是给用户看的提案。
    """

    static func userPrompt(context: Context) -> String {
        var lines: [String] = []
        if !context.recentTurns.isEmpty {
            lines.append("【最近对话】")
            lines.append(contentsOf: context.recentTurns)
        }
        if !context.candidateMemories.isEmpty {
            lines.append("【候选记忆】")
            lines.append(contentsOf: context.candidateMemories)
        }
        if !context.feedbackHints.isEmpty {
            lines.append("【用户反馈】")
            lines.append(contentsOf: context.feedbackHints)
        }
        return lines.joined(separator: "\n")
    }
}

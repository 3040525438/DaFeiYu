import XCTest
import GRDB
import DFCore
@testable import DFData

/// W8：L1–L7 加工闭环（抽取写入 / 情景 / 整理 / 冲突 / 反思 / 图谱 / L7 快照）
final class MemoryProcessingServiceTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var service: MemoryProcessingService!
    private var repo: GRDBMemoryRepository!
    private let now: Int64 = 1_000_000

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFMemoryProcessing-\(UUID().uuidString)", isDirectory: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        repo = GRDBMemoryRepository(database: database)
        service = MemoryProcessingService(database: database, now: { self.now })
    }

    override func tearDownWithError() throws {
        service = nil
        repo = nil
        database = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - 抽取写入

    func testIngestWritesMemoryWithSourcesAndScore() async throws {
        let turn = MemoryTurnSource(
            conversationID: "c1",
            userMessageID: "m1",
            assistantMessageID: "m2",
            text: "她说她最近喜欢上了桂花味的一切，还买了一瓶香水",
            at: now
        )
        let report = try await service.ingest(
            [
                MemoryCandidate(
                    scope: .user,
                    layer: .semantic,
                    category: "preference",
                    title: "喜欢桂花",
                    content: "用户喜欢桂花味的一切",
                    evidenceQuote: "喜欢上了桂花味",
                    importance: 0.6,
                    confidence: 0.8
                )
            ],
            from: turn
        )

        XCTAssertEqual(report.writtenMemoryIDs.count, 1)
        XCTAssertTrue(report.proposalIDs.isEmpty)
        let id = try XCTUnwrap(report.writtenMemoryIDs.first)

        let record = try XCTUnwrap(try await repo.memory(id: id))
        XCTAssertEqual(record.scope, .user)
        XCTAssertEqual(record.layer, "semantic")
        XCTAssertEqual(record.version, 1)
        XCTAssertEqual(record.importanceScore, 0.6)
        XCTAssertEqual(record.importanceSource, "extraction")

        let sources = try await repo.sources(memoryID: id)
        XCTAssertEqual(Set(sources.map(\.sourceID)), ["m1", "m2"], "证据要指回本轮两条原始消息")

        let hits = try await repo.search(query: "桂花", scope: .user, limit: 10)
        XCTAssertTrue(hits.contains { $0.id == id }, "写入后必须可检索")
    }

    func testIngestRoutesImportantCandidateToProposal() async throws {
        let turn = MemoryTurnSource(
            conversationID: "c1",
            userMessageID: "m1",
            text: "她说她最近喜欢上了桂花味的一切",
            at: now
        )
        let report = try await service.ingest(
            [
                MemoryCandidate(
                    scope: .user,
                    category: "preference",
                    title: "喜欢桂花",
                    content: "用户喜欢桂花味的一切",
                    evidenceQuote: "喜欢上了桂花味",
                    importance: 0.95
                )
            ],
            from: turn
        )

        XCTAssertEqual(report.writtenMemoryIDs.count, 0, "高重要度不得直接生效")
        XCTAssertEqual(report.proposalIDs.count, 1)
        let memoryCount = try await int("SELECT count(*) FROM memories")
        XCTAssertEqual(memoryCount, 0)

        let kind = try await string("SELECT kind FROM proposals")
        XCTAssertEqual(kind, "memory")
        let risk = try await string("SELECT risk FROM proposals")
        XCTAssertEqual(risk, "high")
        let payload = try await string("SELECT payload_json FROM proposals")
        XCTAssertTrue(payload?.contains("用户喜欢桂花味的一切") == true)
    }

    func testIngestRejectsFabricatedEvidence() async throws {
        let turn = MemoryTurnSource(
            conversationID: "c1",
            userMessageID: "m1",
            text: "她说她最近喜欢上了桂花味的一切",
            at: now
        )
        let report = try await service.ingest(
            [
                MemoryCandidate(
                    scope: .user,
                    title: "讨厌桂花",
                    content: "用户讨厌桂花",
                    evidenceQuote: "我讨厌桂花"
                )
            ],
            from: turn
        )
        XCTAssertTrue(report.writtenMemoryIDs.isEmpty)
        XCTAssertEqual(report.rejections.first?.reason, .evidenceNotLocated)
        let memoryCount = try await int("SELECT count(*) FROM memories")
        XCTAssertEqual(memoryCount, 0)
    }

    func testIngestDedupesAcrossTurns() async throws {
        func turn(_ user: String, _ assistant: String) -> MemoryTurnSource {
            MemoryTurnSource(
                conversationID: "c1",
                userMessageID: user,
                assistantMessageID: assistant,
                text: "她说她最近喜欢上了桂花味的一切",
                at: now
            )
        }
        let candidate = MemoryCandidate(
            scope: .user,
            category: "preference",
            title: "喜欢桂花",
            content: "用户喜欢桂花味的一切",
            evidenceQuote: "喜欢上了桂花味",
            importance: 0.6
        )

        let first = try await service.ingest([candidate], from: turn("m1", "m2"))
        let second = try await service.ingest([candidate], from: turn("m3", "m4"))

        XCTAssertEqual(first.mergedSourceCount, 0)
        XCTAssertEqual(second.mergedSourceCount, 1, "同内容第二轮只补来源")
        let memoryCount = try await int("SELECT count(*) FROM memories")
        XCTAssertEqual(memoryCount, 1)

        let id = try XCTUnwrap(first.writtenMemoryIDs.first)
        let sources = try await repo.sources(memoryID: id)
        XCTAssertEqual(sources.count, 4, "两轮四条消息都要留证据")
    }

    func testIngestCreatesEpisodeForEpisodicMemory() async throws {
        let turn = MemoryTurnSource(
            conversationID: "c1",
            userMessageID: "m1",
            text: "上个周末我们一起去了杭州看摄影展",
            at: now
        )
        let report = try await service.ingest(
            [
                MemoryCandidate(
                    scope: .shared,
                    layer: .episodic,
                    category: "experience",
                    title: "杭州看展",
                    content: "我们一起去了杭州看摄影展",
                    evidenceQuote: "一起去了杭州看摄影展",
                    importance: 0.6
                )
            ],
            from: turn
        )

        XCTAssertEqual(report.episodeIDs.count, 1, "L2 情景必须落 episodes")
        let episodeID = try XCTUnwrap(report.episodeIDs.first)
        let scope = try await string("SELECT scope FROM episodes WHERE id = '\(episodeID)'")
        XCTAssertEqual(scope, "shared")
        let links = try await int("SELECT count(*) FROM episode_memories WHERE episode_id = '\(episodeID)'")
        XCTAssertEqual(links, 1)

        let memoryID = try XCTUnwrap(report.writtenMemoryIDs.first)
        let graph = try await service.buildGraph(memoryID: memoryID)
        XCTAssertEqual(graph.episodeEdges, 1, "L6 图谱应连到所属情景")
    }

    // MARK: - 整理

    func testConsolidateMergesDuplicatesArchivesColdAndKeepsIndex() async throws {
        let duplicateA = try await repo.insert(
            MemoryDraft(
                title: "喜欢桂花",
                content: "用户喜欢桂花味的一切",
                scope: .user,
                layer: "semantic",
                category: "preference",
                importance: "normal",
                confidence: 0.8,
                salience: 0.8
            ),
            at: now - 1_000
        )
        let duplicateB = try await repo.insert(
            MemoryDraft(
                title: "喜欢桂花",
                content: "用户喜欢桂花味的一切。",
                scope: .user,
                layer: "semantic",
                category: "preference",
                importance: "normal",
                confidence: 0.8,
                salience: 0.9
            ),
            at: now
        )
        let day: Int64 = 24 * 60 * 60 * 1000
        let cold = try await repo.insert(
            MemoryDraft(
                title: "很旧的事",
                content: "很久以前的一条普通记录",
                scope: .user,
                layer: "semantic",
                category: "fact",
                confidence: 0.5,
                salience: 0.1
            ),
            at: now - 200 * day
        )

        let report = try await service.consolidate(scope: .user)
        XCTAssertEqual(report.mergedGroups, 1)
        XCTAssertEqual(report.superseded, 1)
        XCTAssertEqual(report.archived, 1)
        XCTAssertFalse(report.indexRebuilt, "索引与可见行数一致时不应重建")

        let statuses = try await statusesOf([duplicateA.id, duplicateB.id])
        XCTAssertEqual(statuses.filter { $0 == "superseded" }.count, 1)
        XCTAssertEqual(statuses.filter { $0 == "active" }.count, 1)

        let links = try await int("SELECT count(*) FROM memory_links WHERE relation = 'supersedes'")
        XCTAssertEqual(links, 1)

        let archivedAt = try await int64("SELECT archived_at FROM memories WHERE id = '\(cold.id)'")
        XCTAssertNotNil(archivedAt)

        let hits = try await repo.search(query: "桂花", scope: .user, limit: 10)
        XCTAssertEqual(hits.count, 1, "被合并的重复项必须退出检索")

        let stats = try await string("SELECT value FROM settings WHERE key = 'memory.stats.user'")
        XCTAssertNotNil(stats)
        let lastReport = try await string("SELECT value FROM settings WHERE key = 'memory.consolidation.last.user'")
        XCTAssertTrue(lastReport?.contains("\"mergedGroups\":1") == true)
    }

    func testConsolidateDisputesConflictingFacts() async throws {
        try await database.write { db in
            try db.execute(sql: """
            INSERT INTO entities (id, kind, name, normalized_name, created_at, updated_at)
            VALUES ('e1', 'person', '她', '她', 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO entity_facts
                (id, entity_id, attribute, value, valid_from, valid_to, confidence,
                 epistemic_status, source_kind, memory_id, status, created_at, updated_at)
            VALUES ('f1', 'e1', 'city', '杭州', 100, NULL, 0.6, 'observed', 'real_interaction', NULL, 'active', 100, 100),
                   ('f2', 'e1', 'city', '上海', 100, NULL, 0.6, 'observed', 'real_interaction', NULL, 'active', 200, 200)
            """)
        }

        let report = try await service.consolidate(scope: .user)
        XCTAssertEqual(report.disputedFacts, 1)

        let disputed = try await int("SELECT count(*) FROM entity_facts WHERE status = 'disputed'")
        XCTAssertEqual(disputed, 2, "双方都要挂起，不能由 AI 自行裁决")
        let events = try await int("SELECT count(*) FROM change_events WHERE status = 'open'")
        XCTAssertEqual(events, 1)
        let dimension = try await string("SELECT dimension FROM change_events")
        XCTAssertEqual(dimension, "fact:city")

        // 幂等：重复整理不重复建变化事件
        _ = try await service.consolidate(scope: .user)
        let eventsAgain = try await int("SELECT count(*) FROM change_events WHERE status = 'open'")
        XCTAssertEqual(eventsAgain, 1)
    }

    // MARK: - 反思

    func testReflectStoresReflectionsAndDepositsSelfMemory() async throws {
        let draft = ReflectionDraft(
            scope: .selfScope,
            kind: "daily",
            subject: "今天",
            conclusions: [
                ReflectionConclusion(
                    content: "我好像越来越喜欢在晚上聊天",
                    conclusion: "偏好夜间交流",
                    evidenceRefs: ["m1"],
                    epistemicStatus: "inferred",
                    stable: true
                ),
                ReflectionConclusion(content: "没有引用的结论", evidenceRefs: [])
            ],
            availableRefs: ["m1"],
            confidence: 0.7
        )

        let outcome = try await service.reflect(draft)
        XCTAssertEqual(outcome.reflectionIDs.count, 1)
        XCTAssertEqual(outcome.depositedMemoryIDs.count, 1, "稳定结论才沉淀为自身记忆")
        XCTAssertEqual(outcome.rejectedCount, 1)

        let scope = try await string("SELECT scope FROM memories")
        XCTAssertEqual(scope, "self")
        let layer = try await string("SELECT layer FROM memories")
        XCTAssertEqual(layer, "reflective")
        let sourceKind = try await string("SELECT source_kind FROM memories")
        XCTAssertEqual(sourceKind, "model_reflection")
        let epistemic = try await string("SELECT epistemic_status FROM memories")
        XCTAssertEqual(epistemic, "inferred", "反思不得把推测写成事实")

        let refs = try await string("SELECT input_refs_json FROM reflections")
        XCTAssertTrue(refs?.contains("m1") == true)
    }

    func testReflectCorePersonaOnlyProposes() async throws {
        let draft = ReflectionDraft(
            scope: .selfScope,
            conclusions: [
                ReflectionConclusion(
                    content: "我觉得我本质上是个悲观的人",
                    conclusion: "悲观",
                    evidenceRefs: ["m1"],
                    epistemicStatus: "inferred",
                    stable: false,
                    affectsCorePersona: true
                )
            ],
            availableRefs: ["m1"]
        )
        let outcome = try await service.reflect(draft)
        XCTAssertEqual(outcome.proposalIDs.count, 1)
        XCTAssertTrue(outcome.depositedMemoryIDs.isEmpty, "核心人格不得自动改写")
        let kind = try await string("SELECT kind FROM proposals")
        XCTAssertEqual(kind, "persona")
        let risk = try await string("SELECT risk FROM proposals")
        XCTAssertEqual(risk, "high")
        let memoryCount = try await int("SELECT count(*) FROM memories")
        XCTAssertEqual(memoryCount, 0)
    }

    // MARK: - L6 图谱

    func testBuildGraphIsIdempotent() async throws {
        let memory = try await repo.insert(
            MemoryDraft(
                title: "她住在杭州",
                content: "她住在杭州，喜欢桂花",
                scope: .user,
                layer: "semantic",
                category: "fact",
                confidence: 0.7,
                salience: 0.6
            ),
            at: now
        )
        try await database.write { db in
            try db.execute(sql: """
            INSERT INTO entities (id, kind, name, normalized_name, created_at, updated_at)
            VALUES ('e1', 'person', '她', '她', 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO entity_facts
                (id, entity_id, attribute, value, valid_from, valid_to, confidence,
                 epistemic_status, source_kind, memory_id, status, created_at, updated_at)
            VALUES ('f1', 'e1', 'city', '杭州', NULL, NULL, 0.7, 'observed',
                    'real_interaction', ?, 'active', 1, 1)
            """, arguments: [memory.id])
        }

        let first = try await service.buildGraph(memoryID: memory.id)
        XCTAssertFalse(first.nodeID.isEmpty)
        XCTAssertEqual(first.entityEdges, 1)
        let nodes = try await int("SELECT count(*) FROM kg_nodes")
        XCTAssertEqual(nodes, 2)
        let edges = try await int("SELECT count(*) FROM kg_edges WHERE relation = 'about'")
        XCTAssertEqual(edges, 1)

        let second = try await service.buildGraph(memoryID: memory.id)
        XCTAssertEqual(second.nodeID, first.nodeID, "同一记忆只有一个节点")
        XCTAssertEqual(second.entityEdges, 0, "重复派生不得产生重复边")
        let edgesAgain = try await int("SELECT count(*) FROM kg_edges WHERE relation = 'about'")
        XCTAssertEqual(edgesAgain, 1)
    }

    func testBuildGraphRejectsMissingMemory() async throws {
        do {
            _ = try await service.buildGraph(memoryID: "missing")
            XCTFail("不存在的记忆应报错")
        } catch let error as MemoryProcessingError {
            XCTAssertEqual(error, .memoryNotFound("missing"))
        }
    }

    // MARK: - L7 快照

    func testWorkingMemorySnapshotTTL() async throws {
        try await database.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '主会话', 'main', 1, 1)
            """)
        }
        let package = WorkingMemoryAssembler.assemble(
            conversationID: "c1",
            items: [
                WorkingMemoryItem(id: "u1", kind: .currentUserMessage, text: "在吗", estimatedTokens: 3),
                WorkingMemoryItem(id: "p1", kind: .pinnedFact, text: "她今天生病", estimatedTokens: 5)
            ],
            budget: .default,
            at: now
        )
        try await service.saveWorkingMemory(package)

        let loaded = try await service.workingMemory(conversationID: "c1", at: now + 1_000)
        XCTAssertEqual(loaded, package)

        let expired = try await service.workingMemory(
            conversationID: "c1",
            at: now + MemoryProcessingService.workingMemoryTTLMillis + 1
        )
        XCTAssertNil(expired, "超过 24 小时快照不再可用")

        let purged = try await service.purgeExpiredWorkingMemory(
            at: now + MemoryProcessingService.workingMemoryTTLMillis + 1
        )
        XCTAssertEqual(purged, 1)
        let remaining = try await int("SELECT count(*) FROM working_memory_snapshots")
        XCTAssertEqual(remaining, 0)
    }

    func testIngestRejectsEmptySource() async throws {
        do {
            _ = try await service.ingest(
                [],
                from: MemoryTurnSource(conversationID: "c1", userMessageID: "m1", text: "  ", at: now)
            )
            XCTFail("空原文应报错")
        } catch let error as MemoryProcessingError {
            XCTAssertEqual(error, .emptySource)
        }
    }

    // MARK: - 查询辅助

    private func int(_ sql: String) async throws -> Int {
        try await database.dbQueue.read { db in try Int.fetchOne(db, sql: sql) ?? 0 }
    }

    private func int64(_ sql: String) async throws -> Int64? {
        try await database.dbQueue.read { db in try Int64.fetchOne(db, sql: sql) }
    }

    private func string(_ sql: String) async throws -> String? {
        try await database.dbQueue.read { db in try String.fetchOne(db, sql: sql) }
    }

    private func statusesOf(_ ids: [String]) async throws -> [String] {
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        return try await database.dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT status FROM memories WHERE id IN (\(placeholders)) ORDER BY id",
                arguments: StatementArguments(ids)
            )
        }
    }
}

import XCTest
import GRDB
import DFCore
@testable import DFData

/// D62：自主洞察服务（生成 → 证据校验 → 待确认提案 → 用户确认）。
///
/// 边界说明：这里串联真实 SQLite 与真实服务，模型输出由脚本化 Provider 提供；
/// 它验证"决策与落库闭环"，不代表真机 UI 验收。
final class AutonomyInsightServiceTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var service: AutonomyInsightService!

    private static let now: Int64 = 1_700_000_000_000

    private struct ScriptedProvider: ChatModelProvider {
        let identifier = "scripted"
        let capabilities: ModelCapabilities = [.text]
        let response: String

        func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error> {
            let text = response
            return AsyncThrowingStream { continuation in
                continuation.yield(.text(text))
                continuation.yield(.finished(.stop))
                continuation.finish()
            }
        }
    }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFInsight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        service = AutonomyInsightService(
            database: database,
            clock: AutonomyClock(now: { Self.now }, minuteOfDay: { _ in 600 }, dayStart: { _ in 0 })
        )

        try await database.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '大肥鱼', 'main', 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO memories (id, type, title, content, importance, first_seen_at, scope)
            VALUES ('mem1', 'fact', '备考', '用户在准备考试', 'normal', 1, 'shared')
            """)
            try db.execute(sql: """
            INSERT INTO memories (id, type, title, content, importance, first_seen_at, scope, status)
            VALUES ('mem2', 'fact', '旧课程', '摄影课每周三', 'normal', 1, 'shared', 'deleted')
            """)
        }
    }

    override func tearDownWithError() throws {
        service = nil
        database = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - 夹具

    private func context() -> AutonomyInsightService.Context {
        AutonomyInsightService.Context(
            conversationID: "c1",
            recentTurns: [
                "用户：我最近在准备考试，压力有点大",
                "大肥鱼：那我陪你慢慢来",
                "用户：摄影课停了，改成每周自习"
            ],
            candidateMemories: ["mem1：用户在准备考试"]
        )
    }

    private func wrap(_ items: String) -> String {
        #"{"insights":[\#(items)]}"#
    }

    private func memoryCount() throws -> Int {
        try database.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM memories") ?? -1
        }
    }

    private func proposalCount(status: String? = nil) throws -> Int {
        try database.dbQueue.read { db in
            if let status {
                return try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM proposals WHERE kind = ? AND status = ?",
                    arguments: [AutonomyInsightService.proposalKind, status]
                ) ?? -1
            }
            return try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM proposals WHERE kind = ?",
                arguments: [AutonomyInsightService.proposalKind]
            ) ?? -1
        }
    }

    // MARK: - 生成

    func testGeneratePersistsPendingProposalsWithoutWritingMemory() async throws {
        let raw = wrap("""
        {"kind":"recall_recent","summary":"最近在准备考试","evidence":["我最近在准备考试"],"confidence":0.8,"target_memory_id":null},
        {"kind":"worth_recording","summary":"每周自习成为新习惯","evidence":["改成每周自习"],"confidence":0.6,"target_memory_id":null}
        """)
        let outcome = try await service.generate(
            context: context(),
            provider: ScriptedProvider(response: raw),
            model: "scripted"
        )

        XCTAssertTrue(outcome.isStrict)
        XCTAssertEqual(outcome.proposals.count, 2)
        XCTAssertTrue(outcome.proposals.allSatisfy { $0.status == "pending" })
        XCTAssertFalse(outcome.proposals[0].requiresUserConfirmation, "回顾只读，不需要确认")
        XCTAssertTrue(outcome.proposals[1].requiresUserConfirmation, "写入记忆必须先确认")

        // 服务不写记忆：只落提案
        XCTAssertEqual(try memoryCount(), 2, "不得自动写入或删除记忆")
        XCTAssertEqual(try proposalCount(status: "pending"), 2)

        let pending = try await service.pending()
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(Set(pending.map(\.kind)), [.recallRecent, .worthRecording])
    }

    func testHallucinatedEvidenceDroppedEndToEnd() async throws {
        let raw = wrap("""
        {"kind":"worth_recording","summary":"她昨天去了海边","evidence":["她昨天去了海边"],"confidence":0.9,"target_memory_id":null}
        """)
        let outcome = try await service.generate(
            context: context(),
            provider: ScriptedProvider(response: raw),
            model: "scripted"
        )
        XCTAssertTrue(outcome.isStrict)
        XCTAssertTrue(outcome.insights.isEmpty)
        XCTAssertEqual(try proposalCount(), 0, "证据不可信时不得落提案")
    }

    func testTargetMemoryMustExistAndBeActive() async throws {
        let missing = wrap("""
        {"kind":"memory_link","summary":"关联不存在的记忆","evidence":["准备考试"],"confidence":0.7,"target_memory_id":"mem-missing"}
        """)
        let missingOutcome = try await service.generate(
            context: context(),
            provider: ScriptedProvider(response: missing),
            model: "scripted"
        )
        XCTAssertTrue(missingOutcome.proposals.isEmpty, "目标记忆不存在时应丢弃")

        let deleted = wrap("""
        {"kind":"correction_proposal","summary":"修正已删除的记忆","evidence":["摄影课停了"],"confidence":0.7,"target_memory_id":"mem2"}
        """)
        let deletedOutcome = try await service.generate(
            context: context(),
            provider: ScriptedProvider(response: deleted),
            model: "scripted"
        )
        XCTAssertTrue(deletedOutcome.proposals.isEmpty, "目标记忆非 active 时应丢弃")

        let valid = wrap("""
        {"kind":"correction_proposal","summary":"备考安排需要更新","evidence":["改成每周自习"],"confidence":0.7,"target_memory_id":"mem1"}
        """)
        let validOutcome = try await service.generate(
            context: context(),
            provider: ScriptedProvider(response: valid),
            model: "scripted"
        )
        XCTAssertEqual(validOutcome.proposals.count, 1)
        XCTAssertEqual(validOutcome.proposals.first?.targetMemoryID, "mem1")
    }

    func testMalformedOutputReturnsFailureAndPersistsNothing() async throws {
        let outcome = try await service.generate(
            context: context(),
            provider: ScriptedProvider(response: "这不是 JSON"),
            model: "scripted"
        )
        XCTAssertEqual(outcome.failure, .notJSONObject)
        XCTAssertFalse(outcome.isStrict)
        XCTAssertTrue(outcome.proposals.isEmpty)
        XCTAssertEqual(try proposalCount(), 0)
    }

    func testEmptyContextThrows() async throws {
        let empty = AutonomyInsightService.Context(recentTurns: [], candidateMemories: [], feedbackHints: [])
        do {
            _ = try await service.generate(
                context: empty,
                provider: ScriptedProvider(response: wrap("")),
                model: "scripted"
            )
            XCTFail("空上下文必须拒绝生成")
        } catch let error as AutonomyInsightService.InsightError {
            XCTAssertEqual(error, .emptyContext)
        }
    }

    func testDuplicatePendingProposalsAreNotStacked() async throws {
        let raw = wrap("""
        {"kind":"recall_recent","summary":"最近在准备考试","evidence":["我最近在准备考试"],"confidence":0.8,"target_memory_id":null}
        """)
        _ = try await service.generate(
            context: context(),
            provider: ScriptedProvider(response: raw),
            model: "scripted"
        )
        let second = try await service.generate(
            context: context(),
            provider: ScriptedProvider(response: raw),
            model: "scripted"
        )
        XCTAssertTrue(second.proposals.isEmpty, "同类同摘要的待确认提案不重复堆积")
        XCTAssertEqual(try proposalCount(status: "pending"), 1)
    }

    // MARK: - 用户确认

    func testApproveAdvancesStateWithoutTouchingMemory() async throws {
        let raw = wrap("""
        {"kind":"worth_recording","summary":"每周自习成为新习惯","evidence":["改成每周自习"],"confidence":0.6,"target_memory_id":null}
        """)
        let outcome = try await service.generate(
            context: context(),
            provider: ScriptedProvider(response: raw),
            model: "scripted"
        )
        let proposal = try XCTUnwrap(outcome.proposals.first)

        let approved = try await service.approve(id: proposal.id)
        XCTAssertEqual(approved.status, "approved")
        XCTAssertNotNil(approved.resolvedAt)
        XCTAssertEqual(try memoryCount(), 2, "确认提案不等于自动写记忆")
        let remaining = try await service.pending()
        XCTAssertTrue(remaining.isEmpty)

        do {
            _ = try await service.approve(id: proposal.id)
            XCTFail("已处理提案不能重复确认")
        } catch let error as AutonomyInsightService.InsightError {
            XCTAssertEqual(error, .proposalResolved("approved"))
        }
    }

    func testRejectKeepsNoteAndRemovesFromPending() async throws {
        let raw = wrap("""
        {"kind":"stance_change","summary":"对摄影课的态度变淡","evidence":["摄影课停了"],"confidence":0.5,"target_memory_id":null}
        """)
        let outcome = try await service.generate(
            context: context(),
            provider: ScriptedProvider(response: raw),
            model: "scripted"
        )
        let proposal = try XCTUnwrap(outcome.proposals.first)

        try await service.reject(id: proposal.id, note: "这只是临时调整")
        let all = try await service.proposals()
        XCTAssertEqual(all.first?.status, "rejected")
        XCTAssertEqual(all.first?.resolutionNote, "这只是临时调整")
        let pending = try await service.pending()
        XCTAssertTrue(pending.isEmpty)
    }

    func testApproveMissingProposalThrows() async throws {
        do {
            _ = try await service.approve(id: "missing")
            XCTFail("不存在的提案应报错")
        } catch let error as AutonomyInsightService.InsightError {
            XCTAssertEqual(error, .proposalNotFound("missing"))
        }
    }
}

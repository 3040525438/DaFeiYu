import XCTest
import GRDB
import DFCore
@testable import DFData

/// D47：AI 主动创建会话的真实数据层行为（闸门、新建、复用、去重、限额、间隔）。
final class ProactiveConversationServiceTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var autonomy: AutonomyService!
    private var conversations: GRDBConversationAdminRepository!
    private var service: ProactiveConversationService!

    private static let now: Int64 = 1_000 * 3_600_000
    private static let dayStart: Int64 = 990 * 3_600_000

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFNewConv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        let clock = AutonomyClock(
            now: { Self.now },
            minuteOfDay: { _ in 12 * 60 },
            dayStart: { _ in Self.dayStart }
        )
        autonomy = AutonomyService(database: database, clock: clock)
        conversations = GRDBConversationAdminRepository(database: database)
        service = ProactiveConversationService(
            database: database,
            conversations: conversations,
            autonomy: autonomy,
            clock: clock
        )
        try await enableNewConversation()
    }

    override func tearDownWithError() throws {
        service = nil
        conversations = nil
        autonomy = nil
        database = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func enableNewConversation() async throws {
        var policy = AutonomyPolicy.default
        policy.allowNewConversation = true
        try await autonomy.savePolicy(policy)
    }

    private func candidate(
        title: String,
        anchor: String? = nil,
        key: String = "topic:体检"
    ) -> NewConversationCandidate {
        NewConversationCandidate(titleDraft: title, topicAnchor: anchor, dedupeKey: key)
    }

    private func conversationCount() throws -> Int {
        try database.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM conversations") ?? -1
        }
    }

    // MARK: - 闸门

    func testBlockedWhenNewConversationDisabled() async throws {
        var policy = AutonomyPolicy.default
        policy.allowNewConversation = false
        try await autonomy.savePolicy(policy)

        let outcome = try await service.evaluateAndCreate(candidate: candidate(title: "聊聊体检"))
        guard case .skipped(let reason, let runID) = outcome else {
            return XCTFail("应被闸门拦截，实际 \(outcome)")
        }
        XCTAssertTrue(reason.contains("单独关闭"))
        XCTAssertEqual(try conversationCount(), 0, "拦截时不得创建会话")

        let runs = try await autonomy.runs(limit: 10)
        XCTAssertTrue(runs.contains { $0.id == runID && $0.status == .blocked })
    }

    // MARK: - 新建

    func testCreatesProactiveConversation() async throws {
        let outcome = try await service.evaluateAndCreate(candidate: candidate(title: "聊聊体检"))
        guard case .created(let id, let title, let runID) = outcome else {
            return XCTFail("应新建会话，实际 \(outcome)")
        }
        XCTAssertEqual(title, "聊聊体检")

        let summary = try await conversations.summary(id: id)
        XCTAssertEqual(summary?.kind, ProactiveConversationService.conversationKind)
        XCTAssertEqual(summary?.title, "聊聊体检")

        let runs = try await autonomy.runs(limit: 10)
        let run = runs.first { $0.id == runID }
        XCTAssertEqual(run?.kind, ProactiveTrigger.newConversation.rawValue)
        XCTAssertEqual(run?.status, .done)
        XCTAssertEqual(ProactiveConversationService.dedupeKey(fromDetailJSON: run?.detailJSON ?? ""), "topic:体检")
    }

    func testTitleFallsBackToTopicAnchor() async throws {
        let outcome = try await service.evaluateAndCreate(
            candidate: candidate(title: "。", anchor: "她说周五要去体检")
        )
        guard case .created(_, let title, _) = outcome else {
            return XCTFail("应新建会话，实际 \(outcome)")
        }
        XCTAssertEqual(title, "她说周五要去体检")
    }

    // MARK: - 复用 / 去重 / 限额

    func testReusesExistingSameTopicConversation() async throws {
        _ = try await conversations.create(title: "聊聊体检", kind: "chat", at: Self.now - 3_600_000)
        let outcome = try await service.evaluateAndCreate(candidate: candidate(title: "体检"))
        guard case .reused(let id, let title, let runID) = outcome else {
            return XCTFail("应复用已有会话，实际 \(outcome)")
        }
        XCTAssertEqual(title, "聊聊体检")
        XCTAssertEqual(try conversationCount(), 1, "复用不得新建会话")
        let summary = try await conversations.summary(id: id)
        XCTAssertNotNil(summary)

        let runs = try await autonomy.runs(limit: 10)
        XCTAssertEqual(runs.first { $0.id == runID }?.decision, "reuse")
    }

    func testSecondCallWithSameTopicSkips() async throws {
        let first = try await service.evaluateAndCreate(candidate: candidate(title: "聊聊体检"))
        XCTAssertTrue(first.hasConversation)
        // 第二次用同一 dedupeKey，但标题不同以免走"复用"分支
        let second = try await service.evaluateAndCreate(
            candidate: candidate(title: "体检复查", key: "topic:体检")
        )
        guard case .skipped(let reason, _) = second else {
            return XCTFail("同一话题不应重复主动开启，实际 \(second)")
        }
        XCTAssertTrue(reason.contains("之前已经主动开过") || reason.contains("同主题"))
        XCTAssertEqual(try conversationCount(), 1)
    }

    func testDailyLimitBlocksThirdConversation() async throws {
        // 今天已建 2 个主动会话（标题互不相关，避免被判为同主题）
        _ = try await conversations.create(title: "去看牙医", kind: ProactiveConversationService.conversationKind, at: Self.now - 7_200_000)
        _ = try await conversations.create(title: "周末露营", kind: ProactiveConversationService.conversationKind, at: Self.now - 3_600_000)

        let outcome = try await service.evaluateAndCreate(
            candidate: candidate(title: "学吉他", key: "topic:吉他")
        )
        guard case .skipped(let reason, _) = outcome else {
            return XCTFail("达日上限应跳过，实际 \(outcome)")
        }
        XCTAssertTrue(reason.contains("达到上限"))
        XCTAssertEqual(try conversationCount(), 2)
    }

    func testMinIntervalBlocksTooSoon() async throws {
        _ = try await conversations.create(
            title: "去看牙医",
            kind: ProactiveConversationService.conversationKind,
            at: Self.now - 60 * 60_000
        )
        let outcome = try await service.evaluateAndCreate(
            candidate: candidate(title: "学吉他", key: "topic:吉他")
        )
        guard case .skipped(let reason, _) = outcome else {
            return XCTFail("间隔不足应跳过，实际 \(outcome)")
        }
        XCTAssertTrue(reason.contains("还需"))
        XCTAssertEqual(try conversationCount(), 1)
    }

    func testSkipWhenNoTopicAtAll() async throws {
        let outcome = try await service.evaluateAndCreate(
            candidate: candidate(title: "……", anchor: nil, key: "topic:空")
        )
        guard case .skipped(let reason, _) = outcome else {
            return XCTFail("没有话题应跳过，实际 \(outcome)")
        }
        XCTAssertEqual(reason, "没有足够明确的新话题")
        XCTAssertEqual(try conversationCount(), 0)
    }

    // MARK: - JSON 工具

    func testDetailJSONRoundTrip() {
        let json = ProactiveConversationService.detailJSON(
            title: "聊聊体检",
            reason: "新话题",
            dedupeKey: "topic:体检",
            conversationID: "c1"
        )
        XCTAssertEqual(ProactiveConversationService.dedupeKey(fromDetailJSON: json), "topic:体检")
        XCTAssertNil(ProactiveConversationService.dedupeKey(fromDetailJSON: "not-json"))
        XCTAssertNil(ProactiveConversationService.dedupeKey(fromDetailJSON: "{}"))
    }
}

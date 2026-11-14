import XCTest
import GRDB
import DFCore
@testable import DFData

/// 自主调度：策略、五重闸门、任务队列、留痕与后台补算（W7 / D13、D14、D15、D54、D68）
final class AutonomyServiceTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var service: AutonomyService!

    /// 固定时钟：now = 100,000,000ms，当天 0 点 = 90,000,000ms，10:00
    private static let now: Int64 = 100_000_000
    private static let dayStart: Int64 = 90_000_000
    private static let minuteOfDay = 10 * 60

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFAutonomy-\(UUID().uuidString)", isDirectory: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        service = AutonomyService(
            database: database,
            clock: AutonomyClock(
                now: { Self.now },
                minuteOfDay: { _ in Self.minuteOfDay },
                dayStart: { _ in Self.dayStart }
            )
        )
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - 策略

    func testDefaultState() async throws {
        let state = try await service.state()
        XCTAssertEqual(state.policy.dailyLimit, 5)
        XCTAssertEqual(state.policy.minIntervalMinutes, 120)
        XCTAssertEqual(state.policy.notificationLevel, .brief)
        XCTAssertNil(state.pausedUntil)
    }

    func testSavePolicyPersistsAndIsReadBack() async throws {
        var policy = AutonomyPolicy.default
        policy.dailyLimit = 2
        policy.minIntervalMinutes = 30
        policy.notificationLevel = .full
        policy.dailyBudgetYuan = 1.5
        policy.allowNewConversation = true
        try await service.savePolicy(policy)

        let state = try await service.state()
        XCTAssertEqual(state.policy.dailyLimit, 2)
        XCTAssertEqual(state.policy.notificationLevel, .full)
        XCTAssertEqual(state.policy.dailyBudgetYuan ?? -1, 1.5, accuracy: 0.0001)
        XCTAssertTrue(state.policy.allowNewConversation)

        // 新实例读取同一份配置（落库而非内存）
        let another = AutonomyService(
            database: database,
            clock: AutonomyClock(now: { Self.now }, minuteOfDay: { _ in 600 }, dayStart: { _ in Self.dayStart })
        )
        let reloaded = try await another.state()
        XCTAssertEqual(reloaded.policy.dailyLimit, 2)
        XCTAssertTrue(reloaded.policy.allowNewConversation)
    }

    func testResetToDefault() async throws {
        var policy = AutonomyPolicy.default
        policy.dailyLimit = 1
        policy.enabled = false
        try await service.savePolicy(policy)
        try await service.resetToDefault()

        let state = try await service.state()
        XCTAssertTrue(state.policy.enabled)
        XCTAssertEqual(state.policy.dailyLimit, 5)
    }

    // MARK: - 暂停

    func testPauseBlocksThenResumeAllows() async throws {
        try await service.pause(until: Self.now + 3_600_000)
        let blocked = try await service.evaluateSend(trigger: .message)
        XCTAssertFalse(blocked.decision.allowed)
        XCTAssertTrue(blocked.decision.reason?.contains("暂停") == true)

        try await service.resume()
        let allowed = try await service.evaluateSend(trigger: .message)
        XCTAssertTrue(allowed.decision.allowed)
    }

    func testPauseInThePastIsRejected() async throws {
        do {
            try await service.pause(until: Self.now - 1)
            XCTFail("暂停截止时间必须晚于当前时间")
        } catch let error as AutonomyError {
            XCTAssertEqual(error, .invalidPayload("暂停截止时间必须晚于当前时间"))
        }
    }

    // MARK: - 五重闸门

    func testQuietHoursBlocks() async throws {
        var policy = AutonomyPolicy.default
        policy.quietStartMinute = 9 * 60
        policy.quietEndMinute = 12 * 60
        try await service.savePolicy(policy)

        let result = try await service.evaluateSend(trigger: .message)
        XCTAssertFalse(result.decision.allowed)
        XCTAssertEqual(result.decision.reason, "当前处于免打扰时段")
    }

    func testUnauthorizedNotificationBlocksUnlessHidden() async throws {
        var policy = AutonomyPolicy.default
        policy.notificationLevel = .full
        try await service.savePolicy(policy)

        let blocked = try await service.evaluateSend(trigger: .message, notificationsAuthorized: false)
        XCTAssertFalse(blocked.decision.allowed)
        XCTAssertTrue(blocked.decision.reason?.contains("通知授权") == true)

        policy.notificationLevel = .hidden
        try await service.savePolicy(policy)
        let allowed = try await service.evaluateSend(trigger: .message, notificationsAuthorized: false)
        XCTAssertTrue(allowed.decision.allowed, "隐藏档位不展示内容，不应被通知权限阻断")
        XCTAssertNil(NotificationTiering.render(level: .hidden, title: "t", body: "b"))
    }

    func testDailyLimitBlocks() async throws {
        var policy = AutonomyPolicy.default
        policy.dailyLimit = 2
        try await service.savePolicy(policy)
        try await seedSent(at: Self.now - 600_000, text: "a")
        try await seedSent(at: Self.now - 300_000, text: "b")

        let result = try await service.evaluateSend(trigger: .message)
        XCTAssertFalse(result.decision.allowed)
        XCTAssertTrue(result.decision.reason?.contains("上限") == true)
    }

    func testMinIntervalBlocks() async throws {
        try await seedSent(at: Self.now - 600_000, text: "十分钟前")
        let result = try await service.evaluateSend(trigger: .message)
        XCTAssertFalse(result.decision.allowed)
        XCTAssertTrue(result.decision.reason?.contains("最小间隔") == true)
    }

    func testBudgetBlocks() async throws {
        var policy = AutonomyPolicy.default
        policy.dailyBudgetYuan = 1.0
        try await service.savePolicy(policy)

        let allowed = try await service.evaluateSend(trigger: .message, todaySpentYuan: 0.5)
        XCTAssertTrue(allowed.decision.allowed)

        let blocked = try await service.evaluateSend(trigger: .message, todaySpentYuan: 1.0)
        XCTAssertFalse(blocked.decision.allowed)
        XCTAssertTrue(blocked.decision.reason?.contains("预算") == true)
    }

    func testNonUserFacingTriggerSkipsQuietHours() async throws {
        var policy = AutonomyPolicy.default
        policy.quietStartMinute = 9 * 60
        policy.quietEndMinute = 12 * 60
        try await service.savePolicy(policy)

        let result = try await service.evaluateSend(trigger: .memoryConsolidation)
        XCTAssertTrue(result.decision.allowed, "记忆整理不打扰用户，不受免打扰限制")
    }

    func testEveryEvaluationLeavesRunRecord() async throws {
        let allowed = try await service.evaluateSend(trigger: .memoryConsolidation)
        let blocked = try await service.evaluateSend(trigger: .message, notificationsAuthorized: false)
        XCTAssertNotEqual(allowed.runID, blocked.runID)

        let runIDs = try await service.runs()
        XCTAssertEqual(runIDs.count, 2)
        XCTAssertEqual(runIDs.filter { $0.status == .blocked }.count, 1)
        XCTAssertNotNil(runIDs.first(where: { $0.status == .blocked })?.blockReason)
    }

    // MARK: - 任务队列

    func testEnqueueIsIdempotentAndDueSorted() async throws {
        let first = try await service.enqueue(
            kind: .message,
            dedupeKey: "topic-1:followup",
            priority: 3,
            scheduledAt: Self.now - 1_000
        )
        let again = try await service.enqueue(
            kind: .message,
            dedupeKey: "topic-1:followup",
            priority: 1,
            scheduledAt: Self.now - 1_000
        )
        XCTAssertEqual(first.id, again.id)
        let rows = try await int("SELECT count(*) FROM autonomy_tasks")
        XCTAssertEqual(rows, 1)

        _ = try await service.enqueue(
            kind: .memoryConsolidation,
            dedupeKey: "daily:memory",
            priority: 1,
            scheduledAt: Self.now - 5_000
        )
        let due = try await service.dueTasks()
        XCTAssertEqual(due.map(\.dedupeKey), ["daily:memory", "topic-1:followup"])
    }

    func testClaimAndFinish() async throws {
        let task = try await service.enqueue(
            kind: .selfReflection,
            dedupeKey: "reflect-1",
            scheduledAt: Self.now - 1
        )
        let claimed = try await service.claim(taskID: task.id)
        XCTAssertEqual(claimed?.status, .running)
        XCTAssertEqual(claimed?.attempts, 1)

        try await service.finish(taskID: task.id, status: .done, resultJSON: "{\"ok\":true}")
        let status = try await string("SELECT status FROM autonomy_tasks WHERE id = ?", [task.id])
        XCTAssertEqual(status, "done")

        do {
            try await service.finish(taskID: task.id, status: .done)
            XCTFail("已结束的任务不能再次结束")
        } catch let error as AutonomyError {
            XCTAssertEqual(error, .taskNotPending("done"))
        }
    }

    func testClaimExhaustedMarksFailed() async throws {
        let task = try await service.enqueue(
            kind: .suggestion,
            dedupeKey: "suggest-1",
            scheduledAt: Self.now - 1
        )
        try await database.write { db in
            try db.execute(
                sql: "UPDATE autonomy_tasks SET attempts = max_attempts WHERE id = ?",
                arguments: [task.id]
            )
        }
        let claimed = try await service.claim(taskID: task.id)
        XCTAssertNil(claimed)
        let status = try await string("SELECT status FROM autonomy_tasks WHERE id = ?", [task.id])
        XCTAssertEqual(status, "failed")
    }

    func testExpireStale() async throws {
        _ = try await service.enqueue(
            kind: .message,
            dedupeKey: "expired-1",
            scheduledAt: Self.now - 10_000,
            expiresAt: Self.now - 1
        )
        let expired = try await service.expireStale()
        XCTAssertEqual(expired, 1)
        let status = try await string("SELECT status FROM autonomy_tasks WHERE dedupe_key = 'expired-1'")
        XCTAssertEqual(status, "expired")
        let due = try await service.dueTasks()
        XCTAssertTrue(due.isEmpty)
    }

    // MARK: - 后台补算

    func testBackfillCreatesMissingDailyTasks() async throws {
        let first = try await service.backfill()
        XCTAssertEqual(first.missedKinds, [.memoryConsolidation, .selfReflection])
        XCTAssertEqual(first.createdTaskIDs.count, 2)

        // 同一天再补算：dedupe 命中，不重复建任务
        let second = try await service.backfill()
        XCTAssertEqual(second.createdTaskIDs.sorted(), first.createdTaskIDs.sorted())
        let rows = try await int("SELECT count(*) FROM autonomy_tasks")
        XCTAssertEqual(rows, 2)

        // 今天已经成功整理过记忆，就只补自我反思
        let task = try await service.claim(taskID: first.createdTaskIDs[0])
        XCTAssertNotNil(task)
        try await service.finish(taskID: first.createdTaskIDs[0], status: .done)

        let third = try await service.backfill()
        XCTAssertEqual(third.missedKinds, [.selfReflection])
    }

    func testBackfillReportsOverdueAndExpiresStale() async throws {
        let overdue = try await service.enqueue(
            kind: .message,
            dedupeKey: "overdue-1",
            scheduledAt: Self.now - 60_000
        )
        _ = try await service.enqueue(
            kind: .message,
            dedupeKey: "stale-1",
            scheduledAt: Self.now - 60_000,
            expiresAt: Self.now - 1
        )
        let result = try await service.backfill()
        XCTAssertTrue(result.overdueTaskIDs.contains(overdue.id))
        XCTAssertEqual(result.expiredCount, 1)

        // 补算本身也要留痕
        let backfillRuns = try await service.runs()
        XCTAssertTrue(backfillRuns.contains { $0.kind == "backfill" && $0.trigger == "launch_backfill" })
    }

    // MARK: - 工具

    private func seedSent(at millis: Int64, text: String) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO proactive_messages
                    (id, planned_at, text, is_voice, status, sent_at)
                VALUES (?, ?, ?, 0, 'sent', ?)
                """,
                arguments: [UUID().uuidString, millis, text, millis]
            )
        }
    }

    private func int(_ sql: String) async throws -> Int? {
        try await database.dbQueue.read { db in try Int.fetchOne(db, sql: sql) }
    }

    private func string(_ sql: String, _ arguments: StatementArguments = []) async throws -> String? {
        try await database.dbQueue.read { db in
            try String.fetchOne(db, sql: sql, arguments: arguments)
        }
    }
}

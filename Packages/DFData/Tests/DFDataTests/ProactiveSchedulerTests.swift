import XCTest
import GRDB
import DFCore
@testable import DFData

/// N-20：主动检查调度（久未说话 → message 任务），全部规则可在 CI 覆盖。
final class ProactiveSchedulerTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var autonomy: AutonomyService!

    private let now: Int64 = 1_700_000_000_000
    private let dayStart: Int64 = 1_699_900_000_000

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFScheduler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        autonomy = AutonomyService(database: database, clock: clock(minute: 10 * 60))
        try await database.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '大肥鱼', 'main', 1, 1)
            """)
        }
    }

    override func tearDownWithError() throws {
        autonomy = nil
        database = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func clock(minute: Int) -> AutonomyClock {
        let fixedNow = now
        let fixedDayStart = dayStart
        return AutonomyClock(
            now: { fixedNow },
            minuteOfDay: { _ in minute },
            dayStart: { _ in fixedDayStart }
        )
    }

    private func makeScheduler(minute: Int) -> ProactiveScheduler {
        ProactiveScheduler(
            database: database,
            autonomy: autonomy,
            clock: clock(minute: minute)
        )
    }

    private func insertUserMessage(hoursAgo: Int) async throws {
        let at = now - Int64(hoursAgo) * 60 * 60 * 1000
        try await database.write { db in
            try db.execute(sql: """
            INSERT INTO messages
                (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
            VALUES (?, ?, 'c1', 'user', 'text', '在吗', 'sent', 'user', ?)
            """, arguments: [UUID().uuidString, UUID().uuidString, at])
        }
    }

    private func insertSentProactiveMessage() async throws {
        try await database.write { db in
            try db.execute(sql: """
            INSERT INTO proactive_messages (id, planned_at, text, status, sent_at)
            VALUES (?, ?, '早安', 'sent', ?)
            """, arguments: [UUID().uuidString, self.now - 1000, self.now - 500])
        }
    }

    func testEnqueuesWhenUserSilentLongEnough() async throws {
        try await insertUserMessage(hoursAgo: 9)
        let task = try await makeScheduler(minute: 10 * 60).enqueueDueCheckIn()
        XCTAssertNotNil(task)
        XCTAssertEqual(task?.kind, ProactiveTrigger.message.rawValue)
        XCTAssertEqual(task?.dedupeKey, "checkin:\(dayStart)")
        XCTAssertEqual(task?.status, .pending)
    }

    func testSkipsWhenUserRecentlySpoke() async throws {
        try await insertUserMessage(hoursAgo: 1)
        let task = try await makeScheduler(minute: 10 * 60).enqueueDueCheckIn()
        XCTAssertNil(task)
    }

    func testSkipsDuringQuietHours() async throws {
        try await insertUserMessage(hoursAgo: 9)
        let task = try await makeScheduler(minute: 23 * 60 + 30).enqueueDueCheckIn()
        XCTAssertNil(task, "免打扰时段不排任务")
    }

    func testSkipsOutsideDayWindow() async throws {
        try await insertUserMessage(hoursAgo: 9)
        let task = try await makeScheduler(minute: 7 * 60 + 30).enqueueDueCheckIn()
        XCTAssertNil(task, "09:00 之前不主动")
    }

    func testSkipsWhenAutonomyDisabled() async throws {
        try await insertUserMessage(hoursAgo: 9)
        var policy = AutonomyPolicy.default
        policy.enabled = false
        try await autonomy.savePolicy(policy)

        let task = try await makeScheduler(minute: 10 * 60).enqueueDueCheckIn()
        XCTAssertNil(task)
    }

    func testSkipsWhenDailyLimitReached() async throws {
        try await insertUserMessage(hoursAgo: 9)
        try await insertSentProactiveMessage()
        var policy = AutonomyPolicy.default
        policy.dailyLimit = 1
        try await autonomy.savePolicy(policy)

        let task = try await makeScheduler(minute: 10 * 60).enqueueDueCheckIn()
        XCTAssertNil(task)
    }

    func testDedupeSameDay() async throws {
        try await insertUserMessage(hoursAgo: 9)
        let scheduler = makeScheduler(minute: 10 * 60)
        let first = try await scheduler.enqueueDueCheckIn()
        let second = try await scheduler.enqueueDueCheckIn()
        XCTAssertEqual(first?.id, second?.id, "同一天同一类型只排一次")
    }

    // MARK: - D47 新会话评估

    func testEnqueuesNewConversationOncePerDay() async throws {
        var policy = AutonomyPolicy.default
        policy.allowNewConversation = true
        try await autonomy.savePolicy(policy)
        try await insertUserMessage(hoursAgo: 9)

        let scheduler = makeScheduler(minute: 10 * 60)
        let first = try await scheduler.enqueueNewConversationIfDue()
        XCTAssertEqual(first?.kind, ProactiveTrigger.newConversation.rawValue)
        XCTAssertEqual(first?.dedupeKey, "newconv:\(dayStart)")

        _ = try await autonomy.claim(taskID: first?.id ?? "")
        let second = try await scheduler.enqueueNewConversationIfDue()
        XCTAssertNotNil(second, "同一天重复调用返回既有任务（入队幂等）")
        XCTAssertEqual(first?.id, second?.id)
    }

    func testNewConversationRespectsDisabledSwitch() async throws {
        var policy = AutonomyPolicy.default
        policy.allowNewConversation = false
        try await autonomy.savePolicy(policy)
        try await insertUserMessage(hoursAgo: 9)
        let task = try await makeScheduler(minute: 10 * 60).enqueueNewConversationIfDue()
        XCTAssertNil(task, "分项关闭时不得排新会话任务")
    }

    func testNewConversationSkipsWhenUserRecentlySpoke() async throws {
        var policy = AutonomyPolicy.default
        policy.allowNewConversation = true
        try await autonomy.savePolicy(policy)
        try await insertUserMessage(hoursAgo: 1)
        let task = try await makeScheduler(minute: 10 * 60).enqueueNewConversationIfDue()
        XCTAssertNil(task)
    }

    func testNewConversationSkipsDuringQuietHours() async throws {
        var policy = AutonomyPolicy.default
        policy.allowNewConversation = true
        try await autonomy.savePolicy(policy)
        try await insertUserMessage(hoursAgo: 12)
        let task = try await makeScheduler(minute: 23 * 60 + 30).enqueueNewConversationIfDue()
        XCTAssertNil(task, "免打扰时段不得排新会话任务")
    }

    func testQuietRangeWrapsMidnight() {
        XCTAssertTrue(ProactiveScheduler.isQuiet(minute: 23 * 60 + 30, start: 23 * 60, end: 8 * 60))
        XCTAssertTrue(ProactiveScheduler.isQuiet(minute: 7 * 60, start: 23 * 60, end: 8 * 60))
        XCTAssertFalse(ProactiveScheduler.isQuiet(minute: 12 * 60, start: 23 * 60, end: 8 * 60))
        XCTAssertFalse(ProactiveScheduler.isQuiet(minute: 12 * 60, start: 600, end: 600))
    }
}

import XCTest
@testable import DFCore

/// 自主调度纯逻辑：暂停 / 授权 / 预算闸门、通知分档、补算筛选（W7 / D15、D48、D54）
final class AutonomySchedulingTests: XCTestCase {
    private let baseMillis: Int64 = 1_700_000_000_000
    private let noonMinute = 12 * 60

    private func policy(
        level: NotificationLevel = .full,
        budget: Double? = nil,
        quiet: (Int, Int) = (23 * 60, 8 * 60)
    ) -> AutonomyPolicy {
        AutonomyPolicy(
            enabled: true,
            quietStartMinute: quiet.0,
            quietEndMinute: quiet.1,
            minIntervalMinutes: 120,
            dailyLimit: 5,
            notificationLevel: level,
            dailyBudgetYuan: budget,
            allowProactiveMessage: true,
            allowNewConversation: true,
            allowMemoryConsolidation: true,
            allowSelfReflection: true,
            allowSuggestion: true
        )
    }

    // MARK: - 闸门

    func testPausedBlocksAllTriggers() {
        for trigger in ProactiveTrigger.allCases {
            let decision = AutonomyGate.evaluate(
                policy: policy(),
                trigger: trigger,
                nowMillis: baseMillis,
                nowMinuteOfDay: noonMinute,
                lastSentAt: nil,
                todaySentCount: 0,
                pausedUntil: baseMillis + 60_000
            )
            XCTAssertFalse(decision.allowed, "暂停应对 \(trigger.rawValue) 生效")
            XCTAssertTrue(decision.reason?.contains("暂停") == true)
        }
    }

    func testPauseExpiredAllowsAgain() {
        let decision = AutonomyGate.evaluate(
            policy: policy(),
            trigger: .message,
            nowMillis: baseMillis,
            nowMinuteOfDay: noonMinute,
            lastSentAt: nil,
            todaySentCount: 0,
            pausedUntil: baseMillis - 1
        )
        XCTAssertTrue(decision.allowed)
    }

    func testUnauthorizedBlocksVisibleNotificationOnly() {
        let visible = AutonomyGate.evaluate(
            policy: policy(level: .full),
            trigger: .message,
            nowMillis: baseMillis,
            nowMinuteOfDay: noonMinute,
            lastSentAt: nil,
            todaySentCount: 0,
            notificationsAuthorized: false
        )
        XCTAssertFalse(visible.allowed)

        let hidden = AutonomyGate.evaluate(
            policy: policy(level: .hidden),
            trigger: .message,
            nowMillis: baseMillis,
            nowMinuteOfDay: noonMinute,
            lastSentAt: nil,
            todaySentCount: 0,
            notificationsAuthorized: false
        )
        XCTAssertTrue(hidden.allowed)

        let silent = AutonomyGate.evaluate(
            policy: policy(level: .full),
            trigger: .selfReflection,
            nowMillis: baseMillis,
            nowMinuteOfDay: noonMinute,
            lastSentAt: nil,
            todaySentCount: 0,
            notificationsAuthorized: false
        )
        XCTAssertTrue(silent.allowed, "自我反思不触达用户")
    }

    func testBudgetGate() {
        let rejected = AutonomyGate.evaluate(
            policy: policy(budget: 2.0),
            trigger: .message,
            nowMillis: baseMillis,
            nowMinuteOfDay: noonMinute,
            lastSentAt: nil,
            todaySentCount: 0,
            todaySpentYuan: 2.0
        )
        XCTAssertFalse(rejected.allowed)
        XCTAssertTrue(rejected.reason?.contains("预算") == true)

        let allowed = AutonomyGate.evaluate(
            policy: policy(budget: 2.0),
            trigger: .message,
            nowMillis: baseMillis,
            nowMinuteOfDay: noonMinute,
            lastSentAt: nil,
            todaySentCount: 0,
            todaySpentYuan: 1.99
        )
        XCTAssertTrue(allowed.allowed)

        // 预算闸门只管会花钱的用户触达行为
        let consolidation = AutonomyGate.evaluate(
            policy: policy(budget: 0),
            trigger: .memoryConsolidation,
            nowMillis: baseMillis,
            nowMinuteOfDay: noonMinute,
            lastSentAt: nil,
            todaySentCount: 0,
            todaySpentYuan: 10
        )
        XCTAssertTrue(consolidation.allowed)
    }

    func testNegativeBudgetIsClampedToZero() {
        let normalized = policy(budget: -3).normalized()
        XCTAssertEqual(normalized.dailyBudgetYuan, 0)
    }

    // MARK: - 通知分档

    func testNotificationTiering() {
        let full = NotificationTiering.render(level: .full, title: "标题", body: "正文内容")
        XCTAssertEqual(full?.title, "标题")
        XCTAssertEqual(full?.body, "正文内容")

        let brief = NotificationTiering.render(level: .brief, title: "标题", body: "正文内容")
        XCTAssertEqual(brief?.title, "标题")
        XCTAssertNil(brief?.body, "简短档不得暴露正文")

        XCTAssertNil(NotificationTiering.render(level: .hidden, title: "标题", body: "正文内容"))
    }

    // MARK: - 补算

    func testMissedDailyKinds() {
        let dayStart: Int64 = 1_000
        let none = AutonomyBackfill.missedDailyKinds(lastSuccessAt: [:], dayStartMillis: dayStart)
        XCTAssertEqual(none, [.memoryConsolidation, .selfReflection])

        let today = AutonomyBackfill.missedDailyKinds(
            lastSuccessAt: [.memoryConsolidation: 1_500, .selfReflection: 900],
            dayStartMillis: dayStart
        )
        XCTAssertEqual(today, [.selfReflection])

        let allDone = AutonomyBackfill.missedDailyKinds(
            lastSuccessAt: [.memoryConsolidation: 1_500, .selfReflection: 1_500],
            dayStartMillis: dayStart
        )
        XCTAssertTrue(allDone.isEmpty)
    }

    func testOverduePendingFiltering() {
        let make: (String, Int64, Int64?, AutonomyTaskStatus) -> AutonomyTask = { id, scheduled, expires, status in
            AutonomyTask(
                id: id, kind: "message", conversationID: nil, topicID: nil, dedupeKey: id,
                status: status, priority: 3, scheduledAt: scheduled, expiresAt: expires,
                attempts: 0, maxAttempts: 3, lastAttemptAt: nil, payloadJSON: "{}",
                resultJSON: nil, error: nil, createdAt: 0, updatedAt: 0
            )
        }
        let tasks = [
            make("later", 2_000, nil, .pending),
            make("due", 500, nil, .pending),
            make("expired", 500, 900, .pending),
            make("done", 500, nil, .done)
        ]
        let overdue = AutonomyBackfill.overduePending(tasks, nowMillis: 1_000)
        XCTAssertEqual(overdue.map(\.id), ["due"])
    }

    func testTaskCanRetry() {
        let task = AutonomyTask(
            id: "t", kind: "message", conversationID: nil, topicID: nil, dedupeKey: "t",
            status: .failed, priority: 3, scheduledAt: 0, expiresAt: nil,
            attempts: 2, maxAttempts: 3, lastAttemptAt: nil, payloadJSON: "{}",
            resultJSON: nil, error: nil, createdAt: 0, updatedAt: 0
        )
        XCTAssertTrue(task.canRetry(at: 100))
        var expired = task
        expired.expiresAt = 100
        XCTAssertFalse(expired.canRetry(at: 100))
        var exhausted = task
        exhausted.attempts = 3
        XCTAssertFalse(exhausted.canRetry(at: 100))
    }
}

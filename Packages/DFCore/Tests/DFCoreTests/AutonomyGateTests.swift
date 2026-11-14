import XCTest
@testable import DFCore

/// W7-1 / W7-3：自主闸门的五重检查与跨午夜免打扰。
final class AutonomyGateTests: XCTestCase {
    private var policy: AutonomyPolicy { .default }

    func testDisabledPolicyBlocksEverything() {
        var policy = self.policy
        policy.enabled = false
        let decision = AutonomyGate.evaluate(
            policy: policy, trigger: .message, nowMillis: 1_000_000,
            nowMinuteOfDay: 12 * 60, lastSentAt: nil, todaySentCount: 0
        )
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.reason, "自主行为总开关已关闭")
    }

    func testPerTypeSwitchIsRespected() {
        var policy = self.policy
        policy.allowNewConversation = false
        let blocked = AutonomyGate.evaluate(
            policy: policy, trigger: .newConversation, nowMillis: 1_000_000,
            nowMinuteOfDay: 12 * 60, lastSentAt: nil, todaySentCount: 0
        )
        XCTAssertFalse(blocked.allowed)

        let allowed = AutonomyGate.evaluate(
            policy: policy, trigger: .memoryConsolidation, nowMillis: 1_000_000,
            nowMinuteOfDay: 3 * 60, lastSentAt: nil, todaySentCount: 99
        )
        XCTAssertTrue(allowed.allowed, "记忆整理不受免打扰与频率限制")
    }

    func testQuietHoursAcrossMidnight() {
        // 23:00–08:00
        XCTAssertFalse(AutonomyGate.isQuietHours(policy: policy, minuteOfDay: 22 * 60 + 59))
        XCTAssertTrue(AutonomyGate.isQuietHours(policy: policy, minuteOfDay: 23 * 60))
        XCTAssertTrue(AutonomyGate.isQuietHours(policy: policy, minuteOfDay: 2 * 60))
        XCTAssertTrue(AutonomyGate.isQuietHours(policy: policy, minuteOfDay: 7 * 60 + 59))
        XCTAssertFalse(AutonomyGate.isQuietHours(policy: policy, minuteOfDay: 8 * 60))
    }

    func testSameDayQuietWindow() {
        var policy = self.policy
        policy.quietStartMinute = 13 * 60
        policy.quietEndMinute = 15 * 60
        XCTAssertTrue(AutonomyGate.isQuietHours(policy: policy, minuteOfDay: 13 * 60))
        XCTAssertTrue(AutonomyGate.isQuietHours(policy: policy, minuteOfDay: 14 * 60 + 59))
        XCTAssertFalse(AutonomyGate.isQuietHours(policy: policy, minuteOfDay: 15 * 60))
    }

    func testEmptyQuietWindowMeansNeverQuiet() {
        var policy = self.policy
        policy.quietStartMinute = 5 * 60
        policy.quietEndMinute = 5 * 60
        XCTAssertFalse(AutonomyGate.isQuietHours(policy: policy, minuteOfDay: 5 * 60))
    }

    func testDailyLimitBlocksAtBoundary() {
        var policy = self.policy
        policy.dailyLimit = 3
        let decision = AutonomyGate.evaluate(
            policy: policy, trigger: .message, nowMillis: 10_000_000,
            nowMinuteOfDay: 12 * 60, lastSentAt: nil, todaySentCount: 3
        )
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.reason, "已达今日主动消息上限（3 条）")
    }

    func testMinimumIntervalBlocksTooSoon() {
        var policy = self.policy
        policy.minIntervalMinutes = 120
        let last: Int64 = 1_000_000
        // 过去 30 分钟
        let decision = AutonomyGate.evaluate(
            policy: policy, trigger: .message, nowMillis: last + 30 * 60_000,
            nowMinuteOfDay: 12 * 60, lastSentAt: last, todaySentCount: 1
        )
        XCTAssertFalse(decision.allowed)
        XCTAssertTrue(decision.reason?.contains("最小间隔") == true)
    }

    func testAllowedWhenAllConstraintsPass() {
        let decision = AutonomyGate.evaluate(
            policy: policy, trigger: .message, nowMillis: 24 * 60 * 60_000,
            nowMinuteOfDay: 12 * 60, lastSentAt: 0, todaySentCount: 1
        )
        XCTAssertTrue(decision.allowed)
        XCTAssertNil(decision.reason)
    }

    func testNextAllowedMovesPastQuietEnd() {
        var policy = self.policy
        policy.minIntervalMinutes = 0
        let now: Int64 = 1_000_000_000
        // 02:00 → 免打扰 23:00–08:00，应在 6 小时后放行
        let next = AutonomyGate.nextAllowedMillis(
            policy: policy, nowMillis: now, nowMinuteOfDay: 2 * 60,
            lastSentAt: nil, todaySentCount: 0
        )
        XCTAssertEqual(next, now + 6 * 60 * 60_000)
    }

    func testNextAllowedReturnsNilWhenAlreadyAllowed() {
        let next = AutonomyGate.nextAllowedMillis(
            policy: policy, nowMillis: 24 * 60 * 60_000, nowMinuteOfDay: 12 * 60,
            lastSentAt: nil, todaySentCount: 0
        )
        XCTAssertNil(next)
    }

    func testNormalizedClampsOutOfRange() {
        var policy = self.policy
        policy.quietStartMinute = -100
        policy.quietEndMinute = 5000
        policy.minIntervalMinutes = -5
        policy.dailyLimit = 1000
        let normalized = policy.normalized()
        XCTAssertEqual(normalized.quietStartMinute, 0)
        XCTAssertEqual(normalized.quietEndMinute, 1439)
        XCTAssertEqual(normalized.minIntervalMinutes, 0)
        XCTAssertEqual(normalized.dailyLimit, 100)
    }
}

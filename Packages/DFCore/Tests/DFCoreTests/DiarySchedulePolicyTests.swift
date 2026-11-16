import XCTest
@testable import DFCore

/// W6 / D72：每日日记调度策略（纯计算）。
///
/// 只验证"什么时候该写、哪几天欠着"，不涉及系统后台能力——
/// iOS 不保证准点执行，这部分由启动/回前台补偿兜底。
final class DiarySchedulePolicyTests: XCTestCase {
    private let timeZone = "Asia/Shanghai"

    private func millis(_ dayKey: String, hour: Int = 0, minute: Int = 0) -> Int64 {
        let base = LocalDay.millis(dayKey: dayKey, timeZoneIdentifier: timeZone) ?? 0
        return base + Int64((hour * 3600 + minute * 60) * 1000)
    }

    func testTriggerIs23OClockLocal() {
        let trigger = DiarySchedulePolicy.triggerMillis(
            dayKey: "2026-11-17",
            timeZoneIdentifier: timeZone
        )
        XCTAssertEqual(trigger, millis("2026-11-17", hour: 23))
    }

    func testNextTriggerTodayBefore23AndTomorrowAfter23() {
        let before = DiarySchedulePolicy.nextTrigger(
            after: millis("2026-11-17", hour: 22, minute: 59),
            timeZoneIdentifier: timeZone
        )
        XCTAssertEqual(before, millis("2026-11-17", hour: 23))

        let after = DiarySchedulePolicy.nextTrigger(
            after: millis("2026-11-17", hour: 23, minute: 1),
            timeZoneIdentifier: timeZone
        )
        XCTAssertEqual(after, millis("2026-11-18", hour: 23))
    }

    func testIsTodayDue() {
        XCTAssertFalse(
            DiarySchedulePolicy.isTodayDue(
                nowMillis: millis("2026-11-17", hour: 22, minute: 30),
                timeZoneIdentifier: timeZone
            )
        )
        XCTAssertTrue(
            DiarySchedulePolicy.isTodayDue(
                nowMillis: millis("2026-11-17", hour: 23, minute: 30),
                timeZoneIdentifier: timeZone
            )
        )
    }

    func testPendingDaysSkipsGeneratedAndTodayBeforeDue() {
        // 18 日 00:30：17、16、15 三天都可能欠着，18 日还没到点
        let now = millis("2026-11-18", hour: 0, minute: 30)
        let pending = DiarySchedulePolicy.pendingDays(
            nowMillis: now,
            generatedDays: ["2026-11-16"],
            lookbackDays: 3,
            timeZoneIdentifier: timeZone
        )
        XCTAssertEqual(pending, ["2026-11-15", "2026-11-17"])
    }

    func testPendingDaysIncludesTodayAfterDue() {
        let now = millis("2026-11-17", hour: 23, minute: 5)
        let pending = DiarySchedulePolicy.pendingDays(
            nowMillis: now,
            generatedDays: [],
            lookbackDays: 1,
            timeZoneIdentifier: timeZone
        )
        XCTAssertEqual(pending, ["2026-11-16", "2026-11-17"])
    }

    func testPendingDaysIsEmptyWhenEverythingExists() {
        let now = millis("2026-11-18", hour: 9)
        let pending = DiarySchedulePolicy.pendingDays(
            nowMillis: now,
            generatedDays: ["2026-11-15", "2026-11-16", "2026-11-17", "2026-11-18"],
            lookbackDays: 3,
            timeZoneIdentifier: timeZone
        )
        XCTAssertTrue(pending.isEmpty)
    }
}

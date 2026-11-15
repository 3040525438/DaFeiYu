import XCTest
@testable import DFCore

/// D72：显式时区的本地日期处理。
final class LocalDayTests: XCTestCase {
    /// 2026-11-15 12:00:00 UTC = 北京时间 20:00，纽约时间 07:00
    private let noonUTC: Int64 = 1_794_744_000_000

    func testDayKeyUsesGivenTimeZone() {
        XCTAssertEqual(LocalDay.dayKey(millis: noonUTC, timeZoneIdentifier: "Asia/Shanghai"), "2026-11-15")
        XCTAssertEqual(LocalDay.dayKey(millis: noonUTC, timeZoneIdentifier: "UTC"), "2026-11-15")
    }

    func testSameInstantCanBelongToDifferentDays() {
        // 2026-11-15 23:30 UTC：北京已是 16 日 07:30，纽约仍是 15 日 18:30
        let lateUTC: Int64 = 1_794_785_400_000
        XCTAssertEqual(LocalDay.dayKey(millis: lateUTC, timeZoneIdentifier: "UTC"), "2026-11-15")
        XCTAssertEqual(LocalDay.dayKey(millis: lateUTC, timeZoneIdentifier: "Asia/Shanghai"), "2026-11-16")
        XCTAssertEqual(LocalDay.dayKey(millis: lateUTC, timeZoneIdentifier: "America/New_York"), "2026-11-15")
        XCTAssertTrue(LocalDay.isSameDay(lateUTC, lateUTC + 60_000, timeZoneIdentifier: "UTC"))
    }

    func testDayBoundaryDependsOnTimeZone() {
        // 北京 2026-11-15 23:30 = 15:30 UTC；再过 31 分钟北京进入 16 日，UTC 仍是 15 日
        let beijingLate: Int64 = 1_794_756_600_000
        let nextMinute = beijingLate + 31 * 60 * 1000
        XCTAssertEqual(LocalDay.dayKey(millis: beijingLate, timeZoneIdentifier: "Asia/Shanghai"), "2026-11-15")
        XCTAssertEqual(LocalDay.dayKey(millis: nextMinute, timeZoneIdentifier: "Asia/Shanghai"), "2026-11-16")
        XCTAssertEqual(LocalDay.dayKey(millis: beijingLate, timeZoneIdentifier: "UTC"), "2026-11-15")
        XCTAssertEqual(LocalDay.dayKey(millis: nextMinute, timeZoneIdentifier: "UTC"), "2026-11-15")
    }

    func testInvalidTimeZoneFallsBackToCurrent() {
        let fallback = LocalDay.resolvedTimeZoneIdentifier("Mars/Olympus")
        XCTAssertEqual(fallback, TimeZone.current.identifier)
        XCTAssertEqual(LocalDay.resolvedTimeZoneIdentifier(nil), TimeZone.current.identifier)
        XCTAssertEqual(LocalDay.resolvedTimeZoneIdentifier("  "), TimeZone.current.identifier)
        XCTAssertEqual(LocalDay.resolvedTimeZoneIdentifier("Asia/Tokyo"), "Asia/Tokyo")
    }

    func testStartAndEndOfDayBracketTheInstant() throws {
        let start = try XCTUnwrap(LocalDay.startOfDayMillis(millis: noonUTC, timeZoneIdentifier: "Asia/Shanghai"))
        let end = try XCTUnwrap(LocalDay.endOfDayMillis(millis: noonUTC, timeZoneIdentifier: "Asia/Shanghai"))
        XCTAssertLessThan(start, noonUTC)
        XCTAssertGreaterThan(end, noonUTC)
        XCTAssertEqual(end - start + 1, 86_400_000, "非夏令时切换日应为 24 小时")
        XCTAssertEqual(LocalDay.dayKey(millis: start, timeZoneIdentifier: "Asia/Shanghai"), "2026-11-15")
        XCTAssertEqual(LocalDay.dayKey(millis: end, timeZoneIdentifier: "Asia/Shanghai"), "2026-11-15")
    }

    func testDayKeyRoundTrip() throws {
        let millis = try XCTUnwrap(LocalDay.millis(dayKey: "2026-11-15", timeZoneIdentifier: "Asia/Shanghai"))
        XCTAssertEqual(LocalDay.dayKey(millis: millis, timeZoneIdentifier: "Asia/Shanghai"), "2026-11-15")
        XCTAssertEqual(millis, try XCTUnwrap(LocalDay.startOfDayMillis(
            millis: millis, timeZoneIdentifier: "Asia/Shanghai"
        )))
    }

    func testInvalidDayKeysAreRejected() {
        XCTAssertNil(LocalDay.millis(dayKey: "2026-13-01"))
        XCTAssertNil(LocalDay.millis(dayKey: "2026-11"))
        XCTAssertNil(LocalDay.millis(dayKey: ""))
        XCTAssertNil(LocalDay.millis(dayKey: "abc-de-fg"))
        XCTAssertFalse(LocalDay.isValidDayKey("2026/11/15"))
        XCTAssertTrue(LocalDay.isValidDayKey("2026-11-15"))
    }

    func testAddingDaysCrossesMonthAndYear() throws {
        XCTAssertEqual(
            try XCTUnwrap(LocalDay.addingDays(1, to: "2026-11-30", timeZoneIdentifier: "UTC")),
            "2026-12-01"
        )
        XCTAssertEqual(
            try XCTUnwrap(LocalDay.addingDays(1, to: "2026-12-31", timeZoneIdentifier: "UTC")),
            "2027-01-01"
        )
        XCTAssertEqual(
            try XCTUnwrap(LocalDay.addingDays(-1, to: "2026-03-01", timeZoneIdentifier: "UTC")),
            "2026-02-28"
        )
        XCTAssertNil(LocalDay.addingDays(1, to: "bad-key"))
    }

    func testAddingDaysAcrossDaylightSavingKeepsDayKey() throws {
        // 纽约 2026-03-08 进入夏令时（当地 02:00 → 03:00）
        let next = try XCTUnwrap(LocalDay.addingDays(1, to: "2026-03-07", timeZoneIdentifier: "America/New_York"))
        XCTAssertEqual(next, "2026-03-08")
        let after = try XCTUnwrap(LocalDay.addingDays(1, to: "2026-03-08", timeZoneIdentifier: "America/New_York"))
        XCTAssertEqual(after, "2026-03-09")
    }

    // MARK: - 时区变化

    func testTimeZoneChangeDetection() {
        let changed = TimeZoneChange.detect(stored: "Asia/Shanghai", current: "America/New_York")
        XCTAssertTrue(changed.hasChanged)
        XCTAssertNotNil(changed.message)
        XCTAssertTrue(changed.message?.contains("已保存的日记日期不会改变") == true)

        let same = TimeZoneChange.detect(stored: "Asia/Shanghai", current: "Asia/Shanghai")
        XCTAssertFalse(same.hasChanged)
        XCTAssertNil(same.message)

        let firstRun = TimeZoneChange.detect(stored: nil, current: "Asia/Shanghai")
        XCTAssertFalse(firstRun.hasChanged, "首次运行不是变化")
        XCTAssertNil(firstRun.message)
    }
}

import XCTest
@testable import DFCore

/// 时间感知：当前时间描述与相对时间短语解析。
final class CurrentTimeContextTests: XCTestCase {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    private func millis(_ text: String) -> Int64 {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = shanghai
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let date = formatter.date(from: text)!
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    func testDescribeContainsAbsoluteTimeAndAnchors() {
        let now = Date(timeIntervalSince1970: Double(millis("2026-11-17 21:40:00")) / 1000)
        let text = CurrentTimeContext.describe(now: now, timeZone: shanghai, locale: Locale(identifier: "zh_CN"))

        XCTAssertTrue(text.contains("2026年11月17日 21:40:00"))
        XCTAssertTrue(text.contains("星期二"))
        XCTAssertTrue(text.contains("Asia/Shanghai"))
        XCTAssertTrue(text.contains("今天=11月17日"))
        XCTAssertTrue(text.contains("昨天=11月16日"))
        XCTAssertTrue(text.contains("前天=11月15日"))
        XCTAssertTrue(text.contains("今天日期键：2026-11-17"))
        XCTAssertTrue(text.contains("不要凭印象猜测"))
    }

    func testDescribeUsesUserTimeZoneNotUTC() {
        // UTC 2026-11-17 16:30 = 上海 2026-11-18 00:30：必须按用户时区给出 18 日
        let utcFormatter = DateFormatter()
        utcFormatter.locale = Locale(identifier: "en_US_POSIX")
        utcFormatter.timeZone = TimeZone(identifier: "UTC")!
        utcFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let now = utcFormatter.date(from: "2026-11-17 16:30:00")!
        let text = CurrentTimeContext.describe(now: now, timeZone: shanghai)
        XCTAssertTrue(text.contains("2026年11月18日 00:30"))
        XCTAssertTrue(text.contains("今天日期键：2026-11-18"))
    }

    func testResolveSingleDayPhrases() {
        let now = millis("2026-11-17 21:40:00")
        XCTAssertEqual(CurrentTimeContext.resolveDayRange(phrase: "你还记得昨天吗", nowMillis: now, timeZoneIdentifier: "Asia/Shanghai"),
                       CurrentTimeContext.DayRange(start: "2026-11-16", end: "2026-11-16", label: "昨天"))
        XCTAssertEqual(CurrentTimeContext.resolveDayRange(phrase: "前天的事", nowMillis: now, timeZoneIdentifier: "Asia/Shanghai")?.start,
                       "2026-11-15")
        XCTAssertEqual(CurrentTimeContext.resolveDayRange(phrase: "今天聊了什么", nowMillis: now, timeZoneIdentifier: "Asia/Shanghai")?.start,
                       "2026-11-17")
        XCTAssertEqual(CurrentTimeContext.resolveDayRange(phrase: "明天天气", nowMillis: now, timeZoneIdentifier: "Asia/Shanghai")?.start,
                       "2026-11-18")
    }

    func testResolveWeekAndMonthPhrases() {
        let now = millis("2026-11-17 21:40:00") // 周二
        let lastWeek = CurrentTimeContext.resolveDayRange(phrase: "上周我们聊了什么", nowMillis: now, timeZoneIdentifier: "Asia/Shanghai")
        XCTAssertEqual(lastWeek?.start, "2026-11-09")
        XCTAssertEqual(lastWeek?.end, "2026-11-15")

        let thisWeek = CurrentTimeContext.resolveDayRange(phrase: "这周", nowMillis: now, timeZoneIdentifier: "Asia/Shanghai")
        XCTAssertEqual(thisWeek?.start, "2026-11-16")
        XCTAssertEqual(thisWeek?.end, "2026-11-17")

        let lastMonth = CurrentTimeContext.resolveDayRange(phrase: "上个月", nowMillis: now, timeZoneIdentifier: "Asia/Shanghai")
        XCTAssertEqual(lastMonth?.start, "2026-10-01")
        XCTAssertEqual(lastMonth?.end, "2026-10-31")

        let thisMonth = CurrentTimeContext.resolveDayRange(phrase: "本月", nowMillis: now, timeZoneIdentifier: "Asia/Shanghai")
        XCTAssertEqual(thisMonth?.start, "2026-11-01")
        XCTAssertEqual(thisMonth?.end, "2026-11-17")
    }

    func testResolveUnknownPhraseReturnsNil() {
        let now = millis("2026-11-17 21:40:00")
        XCTAssertNil(CurrentTimeContext.resolveDayRange(phrase: "随便聊聊", nowMillis: now, timeZoneIdentifier: "Asia/Shanghai"))
    }
}

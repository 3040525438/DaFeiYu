import Foundation

/// 当前时间上下文（时间感知）。
///
/// 背景：模型自身没有系统时钟，只给一句"现在几点"仍可能被它自己推算错，
/// 尤其是"今天/昨天/上周"这类相对时间。这里把**绝对时间**与**日期锚点**
/// 一次性写清楚，模型只需要照抄，不需要推理。
///
/// 约定：
/// - 时间一律来自设备系统时间 + 用户时区，不由模型猜测；
/// - 日期锚点用同一套 `LocalDay` 口径（与日记 `entry_date` 一致）；
/// - 本类型是纯函数，便于单元测试。
public enum CurrentTimeContext {
    /// 生成注入提示词的"当前状态"文本。
    public static func describe(
        now: Date = Date(),
        timeZone: TimeZone = .current,
        locale: Locale = Locale(identifier: "zh_CN")
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        calendar.firstWeekday = 2 // 周一为一周起点，与中文习惯一致

        let millis = Int64((now.timeIntervalSince1970 * 1000).rounded())

        let absoluteFormatter = DateFormatter()
        absoluteFormatter.locale = locale
        absoluteFormatter.timeZone = timeZone
        absoluteFormatter.calendar = calendar
        absoluteFormatter.dateFormat = "yyyy年M月d日 HH:mm:ss EEEE"

        let dayFormatter = DateFormatter()
        dayFormatter.locale = locale
        dayFormatter.timeZone = timeZone
        dayFormatter.calendar = calendar
        dayFormatter.dateFormat = "M月d日 EEEE"

        func dayLabel(offset: Int) -> String {
            guard let shifted = calendar.date(byAdding: .day, value: offset, to: now) else { return "未知" }
            return dayFormatter.string(from: shifted)
        }

        let utcOffset = timeZone.secondsFromGMT(for: now)
        let sign = utcOffset >= 0 ? "+" : "-"
        let absoluteMinutes = abs(utcOffset) / 60
        let offsetText = String(format: "UTC%@%02d:%02d", sign, absoluteMinutes / 60, absoluteMinutes % 60)

        return """
        当前时间：\(absoluteFormatter.string(from: now))（时区 \(timeZone.identifier)，\(offsetText)）
        日期锚点：今天=\(dayLabel(offset: 0))；昨天=\(dayLabel(offset: -1))；前天=\(dayLabel(offset: -2))；明天=\(dayLabel(offset: 1))
        今天日期键：\(LocalDay.dayKey(millis: millis, timeZoneIdentifier: timeZone.identifier))
        时间使用规则：回答与时间有关的问题（今天几号、昨天聊了什么、上周发生的事等）必须以上面的时间为准，不要凭印象猜测或编造日期。
        """
    }

    /// 相对时间短语解析出的日期键区间（含两端）。
    public struct DayRange: Sendable, Equatable {
        public var start: String
        public var end: String
        public var label: String

        public init(start: String, end: String, label: String) {
            self.start = start
            self.end = end
            self.label = label
        }
    }

    /// 把"今天 / 昨天 / 前天 / 明天 / 上周 / 这周 / 上个月 / 这个月 / 最近"解析成日期区间。
    ///
    /// 只做确定性换算，不理解任意自然语言；无法识别时返回 `nil`，
    /// 由调用方退回"最近若干天"的默认范围。
    public static func resolveDayRange(
        phrase: String,
        nowMillis: Int64 = Clock.nowMillis(),
        timeZoneIdentifier: String? = nil
    ) -> DayRange? {
        let timeZone = LocalDay.resolvedTimeZone(timeZoneIdentifier)
        let today = LocalDay.dayKey(millis: nowMillis, timeZoneIdentifier: timeZone.identifier)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        let todayDate = Date(timeIntervalSince1970: Double(nowMillis) / 1000)

        func key(_ date: Date) -> String {
            LocalDay.dayKey(
                millis: Int64((date.timeIntervalSince1970 * 1000).rounded()),
                timeZoneIdentifier: timeZone.identifier
            )
        }

        func dayRange(_ offset: Int, _ label: String) -> DayRange? {
            guard let shifted = calendar.date(byAdding: .day, value: offset, to: todayDate) else { return nil }
            let value = key(shifted)
            return DayRange(start: value, end: value, label: label)
        }

        let text = phrase

        if text.contains("今天") || text.contains("今日") { return dayRange(0, "今天") }
        if text.contains("昨天") || text.contains("昨日") { return dayRange(-1, "昨天") }
        if text.contains("前天") { return dayRange(-2, "前天") }
        if text.contains("明天") || text.contains("明日") { return dayRange(1, "明天") }
        if text.contains("后天") { return dayRange(2, "后天") }

        if text.contains("上上周") {
            guard let start = weekStart(calendar: calendar, date: todayDate, weekOffset: -2),
                  let end = calendar.date(byAdding: .day, value: 6, to: start) else { return nil }
            return DayRange(start: key(start), end: key(end), label: "上上周")
        }
        if text.contains("上周") || text.contains("上星期") || text.contains("上个星期") {
            guard let start = weekStart(calendar: calendar, date: todayDate, weekOffset: -1),
                  let end = calendar.date(byAdding: .day, value: 6, to: start) else { return nil }
            return DayRange(start: key(start), end: key(end), label: "上周")
        }
        if text.contains("本周") || text.contains("这周") || text.contains("这一周") || text.contains("这个星期") {
            guard let start = weekStart(calendar: calendar, date: todayDate, weekOffset: 0) else { return nil }
            return DayRange(start: key(start), end: today, label: "本周")
        }

        if text.contains("上个月") || text.contains("上月") {
            guard let startOfThisMonth = calendar.dateInterval(of: .month, for: todayDate)?.start,
                  let lastMonthDay = calendar.date(byAdding: .day, value: -1, to: startOfThisMonth),
                  let interval = calendar.dateInterval(of: .month, for: lastMonthDay) else { return nil }
            return DayRange(
                start: key(interval.start),
                end: key(calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start),
                label: "上个月"
            )
        }
        if text.contains("这个月") || text.contains("本月") {
            guard let start = calendar.dateInterval(of: .month, for: todayDate)?.start else { return nil }
            return DayRange(start: key(start), end: today, label: "本月")
        }

        if text.contains("最近") || text.contains("近期") || text.contains("这几天") {
            guard let start = calendar.date(byAdding: .day, value: -6, to: todayDate) else { return nil }
            return DayRange(start: key(start), end: today, label: "最近一周")
        }

        return nil
    }

    /// 指定周偏移的周一 00:00
    private static func weekStart(
        calendar: Calendar,
        date: Date,
        weekOffset: Int
    ) -> Date? {
        var shiftedCalendar = calendar
        shiftedCalendar.firstWeekday = 2
        guard let interval = shiftedCalendar.dateInterval(of: .weekOfYear, for: date) else { return nil }
        return shiftedCalendar.date(byAdding: .weekOfYear, value: weekOffset, to: interval.start)
    }
}

import Foundation

/// 每日日记调度策略（纯计算，不依赖系统定时器）。
///
/// 事实约束：
/// - iOS **不保证**任何后台任务准点执行；`BGAppRefreshTask` 只是"系统愿意时唤醒"。
/// - 因此策略拆成两件事：
///   1. `nextTrigger`：给 `BGAppRefreshTaskRequest.earliestBeginDate` 用，尽量在 23:00 之后唤醒；
///   2. `pendingDays`：App 启动/回到前台时补偿——把"23:00 已过但没写日记"的日子算出来。
///
/// 这两件事都不假装能精确 23:00 执行，而是保证"当天有内容就一定会补上"。
public enum DiarySchedulePolicy {
    /// 每天触发小时（用户本地时区）
    public static let hour = 23
    public static let minute = 0
    /// 默认补偿窗口：最近 3 天（含今天）
    public static let defaultLookbackDays = 3

    /// 某一天 23:00 的毫秒时间戳（本地时区）
    public static func triggerMillis(
        dayKey: String,
        timeZoneIdentifier: String? = nil
    ) -> Int64? {
        guard let start = LocalDay.millis(dayKey: dayKey, timeZoneIdentifier: timeZoneIdentifier) else {
            return nil
        }
        return start + Int64((hour * 3600 + minute * 60) * 1000)
    }

    /// 严格晚于 `nowMillis` 的下一次 23:00
    public static func nextTrigger(
        after nowMillis: Int64,
        timeZoneIdentifier: String? = nil
    ) -> Int64? {
        let today = LocalDay.dayKey(millis: nowMillis, timeZoneIdentifier: timeZoneIdentifier)
        if let todayTrigger = triggerMillis(dayKey: today, timeZoneIdentifier: timeZoneIdentifier),
           todayTrigger > nowMillis {
            return todayTrigger
        }
        guard let tomorrow = LocalDay.addingDays(1, to: today, timeZoneIdentifier: timeZoneIdentifier) else {
            return nil
        }
        return triggerMillis(dayKey: tomorrow, timeZoneIdentifier: timeZoneIdentifier)
    }

    /// 今天的 23:00 是否已过（到了才允许给今天生成日记）
    public static func isTodayDue(
        nowMillis: Int64,
        timeZoneIdentifier: String? = nil
    ) -> Bool {
        let today = LocalDay.dayKey(millis: nowMillis, timeZoneIdentifier: timeZoneIdentifier)
        guard let trigger = triggerMillis(dayKey: today, timeZoneIdentifier: timeZoneIdentifier) else {
            return false
        }
        return nowMillis >= trigger
    }

    /// 需要补生成/生成的日期（升序，含今天；今天只有在 23:00 之后才列入）。
    ///
    /// - Parameters:
    ///   - generatedDays: 已经有日记（含手写）的日期键，这些日期一律不再自动生成
    ///   - lookbackDays: 向前看几天（默认 3，含今天）
    public static func pendingDays(
        nowMillis: Int64,
        generatedDays: Set<String>,
        lookbackDays: Int = defaultLookbackDays,
        timeZoneIdentifier: String? = nil
    ) -> [String] {
        let today = LocalDay.dayKey(millis: nowMillis, timeZoneIdentifier: timeZoneIdentifier)
        let depth = max(0, lookbackDays)
        var result: [String] = []
        for offset in stride(from: -depth, through: 0, by: 1) {
            guard let day = LocalDay.addingDays(offset, to: today, timeZoneIdentifier: timeZoneIdentifier) else { continue }
            if generatedDays.contains(day) { continue }
            if offset == 0, !isTodayDue(nowMillis: nowMillis, timeZoneIdentifier: timeZoneIdentifier) { continue }
            result.append(day)
        }
        return result.sorted()
    }
}

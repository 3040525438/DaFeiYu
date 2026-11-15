import Foundation

// MARK: - 本地日期与时间（D72）
//
// 目标：所有"哪一天"的判断都必须显式带时区，禁止隐式依赖 `Calendar.current`。
// 数据库统一存 UTC 毫秒，只有需要"用户眼中的日期"时才调用这里。
//
// 说明：
// - 日记的 `entry_date` 一旦写入就代表"用户当时所在时区的那一天"，跨时区后不回改；
// - 时区变化只影响此后新建的日记与"今天"的判定；
// - 非法时区标识一律回退到当前设备时区，并可通过 `resolvedTimeZoneIdentifier` 观察。

public enum LocalDay {
    /// 解析时区标识；非法或为空时回退当前设备时区
    public static func resolvedTimeZone(_ identifier: String?) -> TimeZone {
        guard let identifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty,
              let zone = TimeZone(identifier: identifier) else {
            return .current
        }
        return zone
    }

    public static func resolvedTimeZoneIdentifier(_ identifier: String?) -> String {
        resolvedTimeZone(identifier).identifier
    }

    /// 毫秒时间戳在该时区所属的日期键，格式固定 `yyyy-MM-dd`（与 `diary_entries.entry_date` 一致）
    public static func dayKey(millis: Int64, timeZoneIdentifier: String? = nil) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = resolvedTimeZone(timeZoneIdentifier)
        let date = Date(timeIntervalSince1970: Double(millis) / 1000)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return "1970-01-01"
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// 该时区当天 00:00 的毫秒时间戳；解析失败返回 nil
    public static func startOfDayMillis(millis: Int64, timeZoneIdentifier: String? = nil) -> Int64? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = resolvedTimeZone(timeZoneIdentifier)
        let date = Date(timeIntervalSince1970: Double(millis) / 1000)
        guard let start = calendar.dateInterval(of: .day, for: date)?.start else { return nil }
        return Int64((start.timeIntervalSince1970 * 1000).rounded())
    }

    /// 该时区当天的结束毫秒（含当天最后一毫秒）
    public static func endOfDayMillis(millis: Int64, timeZoneIdentifier: String? = nil) -> Int64? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = resolvedTimeZone(timeZoneIdentifier)
        let date = Date(timeIntervalSince1970: Double(millis) / 1000)
        guard let interval = calendar.dateInterval(of: .day, for: date) else { return nil }
        let end = interval.end
        return Int64((end.timeIntervalSince1970 * 1000).rounded()) - 1
    }

    /// 日期键 → 该时区当天 00:00 的毫秒；格式非法返回 nil
    public static func millis(dayKey: String, timeZoneIdentifier: String? = nil) -> Int64? {
        let parts = dayKey.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = resolvedTimeZone(timeZoneIdentifier)
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// 两个时间戳在该时区是否属于同一天
    public static func isSameDay(_ lhs: Int64, _ rhs: Int64, timeZoneIdentifier: String? = nil) -> Bool {
        dayKey(millis: lhs, timeZoneIdentifier: timeZoneIdentifier)
            == dayKey(millis: rhs, timeZoneIdentifier: timeZoneIdentifier)
    }

    /// 日期键加减天数（用于"前一天/后一天"与日期跳转）；结果始终回写为日期键
    public static func addingDays(_ days: Int, to dayKey: String, timeZoneIdentifier: String? = nil) -> String? {
        guard let start = millis(dayKey: dayKey, timeZoneIdentifier: timeZoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = resolvedTimeZone(timeZoneIdentifier)
        let date = Date(timeIntervalSince1970: Double(start) / 1000)
        guard let shifted = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        let result = Int64((shifted.timeIntervalSince1970 * 1000).rounded())
        return self.dayKey(millis: result, timeZoneIdentifier: timeZoneIdentifier)
    }

    /// 校验日期键格式（不校验时区是否存在）
    public static func isValidDayKey(_ value: String) -> Bool {
        millis(dayKey: value) != nil
    }
}

// MARK: - 时区变化

/// 时区变化的记录：只用于提示用户，不影响已保存的日记日期。
public struct TimeZoneChange: Sendable, Equatable {
    public var previousIdentifier: String?
    public var currentIdentifier: String

    public var hasChanged: Bool {
        guard let previousIdentifier else { return false }
        return previousIdentifier != currentIdentifier
    }

    public var message: String? {
        guard hasChanged, let previousIdentifier else { return nil }
        return "检测到时区变化（\(previousIdentifier) → \(currentIdentifier)）。已保存的日记日期不会改变，新建日记与新的一天以当前时区为准。"
    }

    public init(previousIdentifier: String?, currentIdentifier: String) {
        self.previousIdentifier = previousIdentifier
        self.currentIdentifier = currentIdentifier
    }

    /// 比较上次记录的时区与当前时区
    public static func detect(stored: String?, current: String) -> TimeZoneChange {
        TimeZoneChange(previousIdentifier: stored, currentIdentifier: current)
    }
}

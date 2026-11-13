import Foundation

/// 统一时间源：全部使用毫秒级 UTC 时间戳，避免时区导致的排序错乱
public enum Clock {
    public static func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    public static func millis(from date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    public static func date(fromMillis millis: Int64) -> Date {
        Date(timeIntervalSince1970: Double(millis) / 1000)
    }
}

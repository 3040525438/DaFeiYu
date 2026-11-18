/// 本地日期键（与 SwiftUI 版 `LocalDay.dayKey` 一致：`yyyy-MM-dd`）。
library;

/// 两位补零。
String _two(int value) => value.toString().padLeft(2, '0');

/// 把日期格式化为 `yyyy-MM-dd`。
///
/// 只使用传入的 `DateTime` 自身的年月日，不做时区换算；
/// 调用方需保证传入的是"目标时区下的本地时间"。
String dayKey(DateTime date) {
  final year = date.year.toString().padLeft(4, '0');
  return '$year-${_two(date.month)}-${_two(date.day)}';
}

/// 去掉时分秒，得到当天 00:00。
DateTime dateOnly(DateTime date) => DateTime(date.year, date.month, date.day);

/// 在"日"粒度上加减，避免 DST 导致的 23/25 小时偏移。
DateTime addDays(DateTime date, int days) {
  return DateTime(date.year, date.month, date.day + days,
      date.hour, date.minute, date.second);
}

/// 该日期所在周的周一（周一为一周起点）。
DateTime startOfWeek(DateTime date) {
  final base = dateOnly(date);
  return addDays(base, -(base.weekday - 1));
}

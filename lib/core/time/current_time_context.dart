/// 当前时间上下文（与 SwiftUI 版 `CurrentTimeContext` 对齐）。
///
/// 目的：模型没有系统时钟，只告诉它"现在几点"仍可能算错"今天/昨天"。
/// 这里一次性给出绝对时间、时区偏移、日期锚点与日期键，模型只需照抄。
library;

import 'local_day.dart';

/// 相对时间短语解析出的日期键区间（含两端）。
class DayRange {
  const DayRange({required this.start, required this.end, required this.label});

  /// 起始日期键 `yyyy-MM-dd`
  final String start;

  /// 结束日期键 `yyyy-MM-dd`
  final String end;

  /// 短语标签，如"上周"
  final String label;

  @override
  String toString() => 'DayRange($label: $start → $end)';
}

/// 时间上下文生成器（纯函数，便于单元测试）。
class CurrentTimeContext {
  const CurrentTimeContext._();

  static const List<String> _weekdayNames = <String>[
    '周一',
    '周二',
    '周三',
    '周四',
    '周五',
    '周六',
    '周日',
  ];

  static String _weekday(DateTime date) => _weekdayNames[date.weekday - 1];

  static String _two(int value) => value.toString().padLeft(2, '0');

  static String _absolute(DateTime wall) {
    return '${wall.year}年${wall.month}月${wall.day}日 '
        '${_two(wall.hour)}:${_two(wall.minute)}:${_two(wall.second)} '
        '${_weekday(wall)}';
  }

  static String _dayLabel(DateTime wall) {
    return '${wall.month}月${wall.day}日 ${_weekday(wall)}';
  }

  static String _offsetText(Duration offset) {
    final totalMinutes = offset.inMinutes;
    final sign = totalMinutes >= 0 ? '+' : '-';
    final absolute = totalMinutes.abs();
    return 'UTC$sign${_two(absolute ~/ 60)}:${_two(absolute % 60)}';
  }

  /// 生成注入提示词的"当前状态"文本。
  ///
  /// - [now]：绝对时刻。传 `DateTime.now()` 表示设备本地时间；
  /// - [utcOffset]：显式指定偏移时，[now] 被视为 UTC 时刻再换算；
  ///   不传则使用 [now] 自带的本地偏移；
  /// - [timeZoneLabel]：时区展示名。Dart 无法稳定拿到 IANA 名，
  ///   默认写"设备本地时区"，而不是编造一个名字。
  static String describe({
    DateTime? now,
    Duration? utcOffset,
    String? timeZoneLabel,
  }) {
    final instant = now ?? DateTime.now();
    final offset = utcOffset ?? instant.timeZoneOffset;
    final wall = utcOffset == null ? instant : instant.toUtc().add(offset);

    final today = dayKey(wall);
    final yesterday = dayKey(addDays(wall, -1));
    final beforeYesterday = dayKey(addDays(wall, -2));
    final tomorrow = dayKey(addDays(wall, 1));

    final label = timeZoneLabel ??
        (utcOffset == null ? '设备本地时区' : '固定偏移时区');

    return '当前时间：${_absolute(wall)}（时区 $label，${_offsetText(offset)}）\n'
        '日期锚点：今天=${_dayLabel(wall)}；'
        '昨天=${_dayLabel(addDays(wall, -1))}；'
        '前天=${_dayLabel(addDays(wall, -2))}；'
        '明天=${_dayLabel(addDays(wall, 1))}\n'
        '今天日期键：$today（昨天 $yesterday，前天 $beforeYesterday，明天 $tomorrow）\n'
        '时间使用规则：回答与时间有关的问题（今天几号、昨天聊了什么、上周发生的事等）'
        '必须以上面的时间为准，不要凭印象猜测或编造日期。';
  }

  /// 把"今天/昨天/前天/明天/上周/本周/上个月/本月/最近"解析成日期区间。
  ///
  /// 只做确定性换算，不理解任意自然语言；无法识别返回 `null`。
  static DayRange? resolveDayRange(String phrase, {DateTime? now}) {
    final today = dateOnly(now ?? DateTime.now());

    DayRange single(int offset, String label) {
      final value = dayKey(addDays(today, offset));
      return DayRange(start: value, end: value, label: label);
    }

    if (phrase.contains('今天') || phrase.contains('今日')) {
      return single(0, '今天');
    }
    if (phrase.contains('昨天') || phrase.contains('昨日')) {
      return single(-1, '昨天');
    }
    if (phrase.contains('前天')) {
      return single(-2, '前天');
    }
    if (phrase.contains('明天') || phrase.contains('明日')) {
      return single(1, '明天');
    }
    if (phrase.contains('后天')) {
      return single(2, '后天');
    }

    if (phrase.contains('上上周')) {
      final start = addDays(startOfWeek(today), -14);
      final end = addDays(start, 6);
      return DayRange(start: dayKey(start), end: dayKey(end), label: '上上周');
    }
    if (phrase.contains('上周') ||
        phrase.contains('上星期') ||
        phrase.contains('上个星期')) {
      final start = addDays(startOfWeek(today), -7);
      final end = addDays(start, 6);
      return DayRange(start: dayKey(start), end: dayKey(end), label: '上周');
    }
    if (phrase.contains('本周') ||
        phrase.contains('这周') ||
        phrase.contains('这一周') ||
        phrase.contains('这个星期')) {
      return DayRange(
        start: dayKey(startOfWeek(today)),
        end: dayKey(today),
        label: '本周',
      );
    }

    if (phrase.contains('上个月') || phrase.contains('上月')) {
      final start = DateTime(today.year, today.month - 1, 1);
      final end = DateTime(today.year, today.month, 0);
      return DayRange(start: dayKey(start), end: dayKey(end), label: '上个月');
    }
    if (phrase.contains('这个月') || phrase.contains('本月')) {
      return DayRange(
        start: dayKey(DateTime(today.year, today.month, 1)),
        end: dayKey(today),
        label: '本月',
      );
    }

    if (phrase.contains('最近') ||
        phrase.contains('近期') ||
        phrase.contains('这几天')) {
      return DayRange(
        start: dayKey(addDays(today, -6)),
        end: dayKey(today),
        label: '最近一周',
      );
    }

    return null;
  }
}

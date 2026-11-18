import 'package:dafeiyu_flutter/core/time/current_time_context.dart';
import 'package:dafeiyu_flutter/core/time/local_day.dart';
import 'package:test/test.dart';

void main() {
  group('dayKey', () {
    test('格式为 yyyy-MM-dd', () {
      expect(dayKey(DateTime(2026, 1, 5)), '2026-01-05');
    });
  });

  group('CurrentTimeContext.describe', () {
    test('固定时刻与偏移生成锚点', () {
      final text = CurrentTimeContext.describe(
        now: DateTime.utc(2026, 11, 18, 3, 30, 0),
        utcOffset: const Duration(hours: 8),
        timeZoneLabel: 'Asia/Shanghai',
      );

      expect(text, contains('2026年11月18日 11:30:00 周三'));
      expect(text, contains('UTC+08:00'));
      expect(text, contains('今天=11月18日 周三'));
      expect(text, contains('昨天=11月17日 周二'));
      expect(text, contains('前天=11月16日 周一'));
      expect(text, contains('明天=11月19日 周四'));
      expect(text, contains('今天日期键：2026-11-18'));
    });
  });

  group('CurrentTimeContext.resolveDayRange', () {
    final now = DateTime(2026, 11, 18, 10);

    test('今天/昨天/前天/明天', () {
      expect(CurrentTimeContext.resolveDayRange('今天', now: now)!.start,
          '2026-11-18');
      expect(CurrentTimeContext.resolveDayRange('昨天', now: now)!.start,
          '2026-11-17');
      expect(CurrentTimeContext.resolveDayRange('前天', now: now)!.start,
          '2026-11-16');
      expect(CurrentTimeContext.resolveDayRange('明天', now: now)!.start,
          '2026-11-19');
    });

    test('上周为完整七天的周一到周日', () {
      final range = CurrentTimeContext.resolveDayRange('上周', now: now)!;
      expect(range.start, '2026-11-09');
      expect(range.end, '2026-11-15');
    });

    test('本周为周一到今天', () {
      final range = CurrentTimeContext.resolveDayRange('本周', now: now)!;
      expect(range.start, '2026-11-16');
      expect(range.end, '2026-11-18');
    });

    test('上个月为完整自然月', () {
      final range = CurrentTimeContext.resolveDayRange('上个月', now: now)!;
      expect(range.start, '2026-10-01');
      expect(range.end, '2026-10-31');
    });

    test('最近为七天窗口', () {
      final range = CurrentTimeContext.resolveDayRange('最近', now: now)!;
      expect(range.start, '2026-11-12');
      expect(range.end, '2026-11-18');
    });

    test('无法识别返回 null', () {
      expect(CurrentTimeContext.resolveDayRange('随便说说', now: now), isNull);
    });
  });
}

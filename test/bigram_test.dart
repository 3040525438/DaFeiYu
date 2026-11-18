import 'package:dafeiyu_flutter/core/text/bigram.dart';
import 'package:test/test.dart';

/// 与 SwiftUI 版 `V2Memory.bigram` 的对齐验证。
/// 这些用例直接决定 FTS 索引与关键词命中是否与旧版一致。
void main() {
  group('bigram', () {
    test('四字中文切为相邻二字词', () {
      expect(bigram('今天天气'), '今天 天天 天气');
    });

    test('单字保留', () {
      expect(bigram('好'), '好');
    });

    test('英文连续段整体小写', () {
      expect(bigram('Hello World'), 'hello world');
    });

    test('中英混合按边界切分', () {
      expect(bigram('AI很好'), 'ai 很好');
    });

    test('标点作为分隔符', () {
      expect(bigram('你好，世界！'), '你好 世界');
    });

    test('数字连续段保留', () {
      // 数字段与中文段在字符类别切换处分开
      expect(bigram('2026年11月'), '2026 年 11 月');
    });

    test('空串返回空串', () {
      expect(bigram(''), '');
    });

    test('纯标点返回空串', () {
      expect(bigram('！？，。'), '');
    });
  });
}

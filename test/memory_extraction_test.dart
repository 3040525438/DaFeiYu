/// 记忆抽取纯逻辑单测：解析、证据定位、去重、路由（对齐原版用例口径）。
library;

import 'package:dafeiyu_flutter/core/memory/memory_extraction.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final policy = MemoryExtractionPolicy();

  group('jsonArraySubstring', () {
    test('从围栏和废话中截取数组', () {
      const raw = '好的，以下是结果：\n```json\n[{"content":"x"}]\n```\n希望有帮助';
      expect(MemoryExtractionParser.jsonArraySubstring(raw),
          '[{"content":"x"}]');
    });

    test('无数组返回 null', () {
      expect(MemoryExtractionParser.jsonArraySubstring('没有数组'), isNull);
    });
  });

  group('MemoryExtractionParser.parse', () {
    test('正常解析并补全去重键', () {
      const userText = '我最近开始学吉他了，每天练半小时';
      const assistantText = '坚持练习一定能进步！';
      const raw = '''
[{"subject":"user","layer":"semantic","category":"preference",
  "title":"学吉他","content":"用户开始学吉他，每天练半小时",
  "evidence":"我最近开始学吉他了，每天练半小时",
  "importance":0.6,"confidence":0.9}]
''';
      final result = MemoryExtractionParser.parse(
        raw,
        sourceText: '$userText\n$assistantText',
      );
      expect(result.accepted.length, 1);
      final candidate = result.accepted.first;
      expect(candidate.scope, 'user');
      expect(candidate.category, 'preference');
      expect(candidate.dedupeKey, isNotNull);
      expect(candidate.dedupeKey, startsWith('user|semantic|preference|'));
    });

    test('证据定位失败整条丢弃', () {
      const raw = '''
[{"subject":"user","category":"fact","title":"x",
  "content":"用户养了狗","evidence":"用户养了一只金毛",
  "importance":0.5,"confidence":0.8}]
''';
      final result = MemoryExtractionParser.parse(
        raw,
        sourceText: '我家里没有宠物',
      );
      expect(result.accepted, isEmpty);
      expect(result.rejections.first.reason,
          MemoryScreenRejectionReason.evidenceNotLocated);
    });

    test('非 JSON / 空数组退化为零条', () {
      expect(
        MemoryExtractionParser.parse('完全不是 JSON', sourceText: 'x').accepted,
        isEmpty,
      );
      expect(MemoryExtractionParser.parse('[]', sourceText: 'x').accepted, isEmpty);
    });

    test('unknown 主语落 shared 且标记待确认', () {
      const raw = '''
[{"subject":"unknown","category":"fact","title":"x",
  "content":"有人喜欢跑步","evidence":"喜欢跑步",
  "importance":0.4,"confidence":0.5}]
''';
      final result = MemoryExtractionParser.parse(
        raw,
        sourceText: '我喜欢跑步',
      );
      expect(result.accepted.first.scope, 'shared');
      expect(result.accepted.first.scopeNeedsConfirmation, isTrue);
      // unknown → route confirm
      expect(
        policy.route(result.accepted.first),
        MemoryWriteRoute.confirm,
      );
    });
  });

  group('MemoryExtractionPolicy', () {
    MemoryCandidate candidate({
      String content = '用户喜欢火锅',
      String category = 'fact',
      String scope = 'user',
    }) =>
        MemoryCandidate(
          title: 't',
          content: content,
          evidenceQuote: '火锅',
          scope: scope,
          category: category,
        );

    test('批内重复（相似度过阈值）被拒', () {
      final result = policy.screen(
        [
          candidate(content: '用户非常喜欢吃火锅，每周都去吃一次'),
          candidate(content: '用户非常喜欢吃火锅，每周都去吃一次'),
        ],
        sourceText: '火锅',
      );
      expect(result.accepted.length, 1);
      expect(result.rejections.first.reason,
          MemoryScreenRejectionReason.duplicateInBatch);
    });

    test('单轮上限截断', () {
      final result = policy.screen(
        List.generate(
          12,
          (i) => MemoryCandidate(
            title: 't$i',
            content: '事实$i：用户喜欢的数字是 $i 号，这是第 $i 条独立事实',
            evidenceQuote: '数字是 $i 号',
            scope: 'user',
            category: 'fact',
          ),
        ).toList(),
        sourceText: '数字是 0 号 数字是 1 号 数字是 2 号 数字是 3 号 '
            '数字是 4 号 数字是 5 号 数字是 6 号 数字是 7 号 '
            '数字是 8 号 数字是 9 号 数字是 10 号 数字是 11 号',
      );
      expect(result.accepted.length, 8);
      // 被预算裁掉的数量 = 总数 - 接受 - 其他原因拒绝
      expect(
        result.droppedByBudget,
        12 - 8 - result.rejections.length,
      );
    });

    test('高重要度或关键类别走确认', () {
      final important = MemoryCandidate(
        title: 't',
        content: '用户喜欢火锅',
        evidenceQuote: '火锅',
        scope: 'user',
        category: 'fact',
        importance: 0.9,
      );
      expect(policy.route(important), MemoryWriteRoute.confirm);
      final critical = MemoryCandidate(
        title: 't',
        content: '用户是设计师',
        evidenceQuote: '设计师',
        scope: 'user',
        category: 'identity',
        importance: 0.3,
      );
      expect(policy.route(critical), MemoryWriteRoute.confirm);
    });

    test('低重要度普通事实直写', () {
      final c = MemoryCandidate(
        title: 't',
        content: '用户今天去了公园',
        evidenceQuote: '公园',
        scope: 'user',
        category: 'event',
        importance: 0.3,
        confidence: 0.6,
      );
      expect(policy.route(c), MemoryWriteRoute.direct);
    });

    test('locate：子串命中与 bigram 兜底', () {
      expect(
        policy.locate(quote: '学吉他', source: '我最近开始学吉他了'),
        isTrue,
      );
      // 完全不相关
      expect(
        policy.locate(quote: '量子力学很难', source: '今天天气很好'),
        isFalse,
      );
    });
  });
}

/// 记忆抽取与加工（与 SwiftUI 版 `MemoryProcessing` / `MemoryExtraction` 1:1 对齐）。
///
/// 七层是**加工深度**，不是七个数据库：只有 episodic / semantic / procedural /
/// reflective 落在 `memories` 表内；raw/graph/working 落到语义层。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

// MARK: - 层级

/// 记忆层级（加工深度）。
enum MemoryLayer {
  raw('raw'),
  episodic('episodic'),
  semantic('semantic'),
  procedural('procedural'),
  reflective('reflective'),
  graph('graph'),
  working('working');

  const MemoryLayer(this.value);
  final String value;

  static MemoryLayer fromValue(String? raw, [MemoryLayer fallback = MemoryLayer.semantic]) =>
      values.firstWhere((l) => l.value == raw, orElse: () => fallback);

  /// 是否以 memories 行承载
  bool get persistsInMemories =>
      this == MemoryLayer.episodic ||
      this == MemoryLayer.semantic ||
      this == MemoryLayer.procedural ||
      this == MemoryLayer.reflective;

  /// 该层允许的归属（L1 只归 shared）
  Set<String> get allowedScopes =>
      this == MemoryLayer.raw ? const {'shared'} : const {'user', 'shared', 'self'};
}

// MARK: - 三主体治理

/// 记忆主体：这句话的主语是谁，记忆就属于谁。
enum MemorySubject { user, both, aiSelf, unknown }

class MemoryGovernance {
  const MemoryGovernance._();

  /// 涉及关系/底线的类别，写入必须走用户确认。
  static const Set<String> criticalCategories = <String>{
    'relationship', 'boundary', 'promise', 'identity', 'value', 'emotion_pattern',
  };

  /// 主语 → 归属；无法判断时落 shared 且必须标记待确认，禁止静默归类。
  static (String scope, bool needsConfirmation) resolveScope(MemorySubject subject) {
    switch (subject) {
      case MemorySubject.user:
        return ('user', false);
      case MemorySubject.both:
        return ('shared', false);
      case MemorySubject.aiSelf:
        return ('self', false);
      case MemorySubject.unknown:
        return ('shared', true);
    }
  }

  static bool validate(String scope, MemoryLayer layer) =>
      layer.allowedScopes.contains(scope);

  static bool requiresConfirmation(String category) =>
      criticalCategories.contains(normalizeCategory(category));

  static String normalizeCategory(String category) =>
      category.trim().toLowerCase();

  static MemorySubject subjectFromValue(String? raw) {
    switch ((raw ?? 'unknown').toLowerCase()) {
      case 'user':
        return MemorySubject.user;
      case 'both':
        return MemorySubject.both;
      case 'self':
        return MemorySubject.aiSelf;
      default:
        return MemorySubject.unknown;
    }
  }
}

// MARK: - 抽取候选

class MemoryCandidate {
  MemoryCandidate({
    required this.title,
    required this.content,
    required this.evidenceQuote,
    this.scope = 'shared',
    this.layer = MemoryLayer.semantic,
    this.category = 'fact',
    this.importance = 0.5,
    this.confidence = 0.6,
    this.epistemicStatus = 'observed',
    this.sourceKind = 'real_interaction',
    this.scopeNeedsConfirmation = false,
    this.dedupeKey,
  });

  final String scope;
  final MemoryLayer layer;
  final String category;
  final String title;
  final String content;

  /// 必须能在本轮原文中定位的摘录（防编造第一道闸）
  final String evidenceQuote;
  final double importance;
  final double confidence;
  final String epistemicStatus;
  final String sourceKind;
  final bool scopeNeedsConfirmation;
  String? dedupeKey;
}

class MemoryScreenRejection {
  MemoryScreenRejection(this.title, this.reason);

  final String title;
  final MemoryScreenRejectionReason reason;
}

enum MemoryScreenRejectionReason {
  emptyContent,
  evidenceNotLocated,
  invalidScopeForLayer,
  duplicateInBatch,
  budgetExceeded,
}

class MemoryScreenResult {
  MemoryScreenResult({
    List<MemoryCandidate>? accepted,
    List<MemoryScreenRejection>? rejections,
    this.droppedByBudget = 0,
  })  : accepted = accepted ?? <MemoryCandidate>[],
        rejections = rejections ?? <MemoryScreenRejection>[];

  final List<MemoryCandidate> accepted;
  final List<MemoryScreenRejection> rejections;
  final int droppedByBudget;
}

enum MemoryWriteRoute { direct, confirm }

// MARK: - 抽取策略（纯逻辑）

class MemoryExtractionPolicy {
  MemoryExtractionPolicy({
    this.maxCandidatesPerTurn = 8,
    this.confirmThreshold = 0.7,
    this.dedupeSimilarityThreshold = 0.82,
    this.evidenceSimilarityFloor = 0.72,
  });

  /// 单轮最多产出候选数
  final int maxCandidatesPerTurn;

  /// 重要度达到该阈值必须确认
  final double confirmThreshold;

  /// 批内相似度达到该阈值视为重复
  final double dedupeSimilarityThreshold;

  /// 证据高相似兜底阈值（子串找不到时的第二判据）
  final double evidenceSimilarityFloor;

  static final MemoryExtractionPolicy instance = MemoryExtractionPolicy();

  /// 一次筛掉：空内容、证据无法定位、层级/归属非法、批内重复，并截断到单轮上限。
  MemoryScreenResult screen(
    List<MemoryCandidate> candidates, {
    required String sourceText,
    int? remainingBudget,
  }) {
    final accepted = <MemoryCandidate>[];
    final rejections = <MemoryScreenRejection>[];
    var droppedByBudget = 0;
    final budget = remainingBudget ?? 0x7FFFFFFFFFFFFFFF;

    for (final candidate in candidates) {
      final title = candidate.title.trim();
      final content = candidate.content.trim();
      if (content.isEmpty) {
        rejections.add(MemoryScreenRejection(title, MemoryScreenRejectionReason.emptyContent));
        continue;
      }
      if (!locate(quote: candidate.evidenceQuote, source: sourceText)) {
        rejections.add(MemoryScreenRejection(title, MemoryScreenRejectionReason.evidenceNotLocated));
        continue;
      }
      if (!MemoryGovernance.validate(candidate.scope, candidate.layer)) {
        rejections.add(MemoryScreenRejection(title, MemoryScreenRejectionReason.invalidScopeForLayer));
        continue;
      }
      if (accepted.any((existing) => isDuplicate(candidate, existing))) {
        rejections.add(MemoryScreenRejection(title, MemoryScreenRejectionReason.duplicateInBatch));
        continue;
      }
      if (accepted.length >= maxCandidatesPerTurn) {
        droppedByBudget++;
        continue;
      }
      if (accepted.length >= budget) {
        droppedByBudget++;
        continue;
      }
      accepted.add(candidate);
    }

    return MemoryScreenResult(
      accepted: accepted,
      rejections: rejections,
      droppedByBudget: droppedByBudget,
    );
  }

  bool isDuplicate(MemoryCandidate lhs, MemoryCandidate rhs) {
    if (lhs.scope != rhs.scope || lhs.layer != rhs.layer) return false;
    if (MemoryGovernance.normalizeCategory(lhs.category) !=
        MemoryGovernance.normalizeCategory(rhs.category)) {
      return false;
    }
    final left = lhs.dedupeKey;
    final right = rhs.dedupeKey;
    if (left != null && right != null && left == right) return true;
    return similarity(lhs.content, rhs.content) >= dedupeSimilarityThreshold;
  }

  /// 摘录必须能在原文中定位：先做归一化子串匹配，再退到 bigram 相似度。
  bool locate({required String quote, required String source}) {
    final normalizedQuote = normalize(quote);
    final normalizedSource = normalize(source);
    if (normalizedQuote.length < 2 || normalizedSource.isEmpty) return false;
    if (normalizedSource.contains(normalizedQuote)) return true;
    return similarity(quote, source) >= evidenceSimilarityFloor;
  }

  /// bigram Jaccard 相似度（0…1）
  double similarity(String lhs, String rhs) {
    final left = bigrams(lhs);
    final right = bigrams(rhs);
    if (left.isEmpty || right.isEmpty) return 0;
    final intersection = left.intersection(right).length;
    final union = left.union(right).length;
    if (union == 0) return 0;
    return intersection / union;
  }

  /// 去重键：scope|layer|category|sha256 前 24 位
  String normalizedDedupeKey(MemoryCandidate candidate) {
    final category = MemoryGovernance.normalizeCategory(candidate.category);
    final body = normalize(candidate.content);
    final digest = sha256.convert(utf8.encode(body)).toString();
    return '${candidate.scope}|${candidate.layer.value}|$category|'
        '${digest.substring(0, 24)}';
  }

  /// 重要度高、涉及关系/底线、归属待确认 → 必须走确认提案
  MemoryWriteRoute route(MemoryCandidate candidate) {
    if (candidate.importance >= confirmThreshold) return MemoryWriteRoute.confirm;
    if (MemoryGovernance.requiresConfirmation(candidate.category)) {
      return MemoryWriteRoute.confirm;
    }
    if (candidate.scopeNeedsConfirmation) return MemoryWriteRoute.confirm;
    return MemoryWriteRoute.direct;
  }

  /// 归一化：只保留字母/数字/汉字并转小写
  static String normalize(String text) {
    final buffer = StringBuffer();
    for (final rune in text.toLowerCase().runes) {
      final ch = String.fromCharCode(rune);
      if (_isLetterOrNumber(rune)) buffer.write(ch);
    }
    return buffer.toString();
  }

  static bool _isLetterOrNumber(int rune) {
    return (rune >= 0x30 && rune <= 0x39) || // 0-9
        (rune >= 0x41 && rune <= 0x5A) || // A-Z
        (rune >= 0x61 && rune <= 0x7A) || // a-z
        (rune >= 0x4E00 && rune <= 0x9FFF) || // CJK 基本区
        (rune >= 0x3400 && rune <= 0x4DBF) || // CJK 扩展 A
        (rune >= 0xF900 && rune <= 0xFAFF) || // CJK 兼容
        (rune >= 0x00C0 && rune <= 0x024F); // 拉丁扩展
  }

  /// 字符级 bigram 集合（与 Swift 版口径一致）
  static Set<String> bigrams(String text) {
    final chars = normalize(text).split('');
    if (chars.isEmpty) return <String>{};
    if (chars.length == 1) return <String>{chars.first};
    return <String>{
      for (var i = 0; i < chars.length - 1; i++) chars[i] + chars[i + 1],
    };
  }
}

// MARK: - 抽取提示词与解析

/// 一次抽取的输入：只有本轮真实发生的对话，不夹带猜测。
class MemoryExtractionInput {
  const MemoryExtractionInput({
    required this.userText,
    required this.assistantText,
    this.knownFacts = const <String>[],
  });

  final String userText;
  final String assistantText;
  final List<String> knownFacts;
}

class MemoryExtractionPrompt {
  const MemoryExtractionPrompt._();

  static const String version = 'v1';

  static const String system = '''
你是记忆抽取器，只输出 JSON 数组，不要任何解释、前缀或代码块标记。
从这一轮对话中抽取**值得长期记住**的事实，最多 8 条；没有就输出 []。

每条字段：
- subject: "user"（关于用户）/ "both"（关于我们）/ "self"（关于你自己）/ "unknown"（无法判断）
- layer: "episodic"（一次具体经历）/ "semantic"（稳定事实）/ "procedural"（偏好与习惯做法）/ "reflective"（对关系的思考）
- category: 小写英文，如 fact / preference / relationship / boundary / promise / identity / value / emotion_pattern / event
- title: 不超过 20 字
- content: 一句话完整陈述，主语明确
- evidence: **必须逐字摘自用户原话**的片段，不得改写、不得拼接
- importance: 0 到 1
- confidence: 0 到 1

硬规则：
1. evidence 在用户原话中找不到就不要输出该条；
2. 不推断用户没说过的喜好、身份、关系；
3. 不把寒暄、工具调用、系统提示当作记忆；
4. 同一条内容只出现一次。''';

  static String userMessage(MemoryExtractionInput input) {
    final parts = <String>[];
    if (input.knownFacts.isNotEmpty) {
      final facts = input.knownFacts.take(20).map((f) => '- $f').join('\n');
      parts.add('已知事实（不要重复）：\n$facts');
    }
    parts.add('用户说：\n${input.userText}');
    parts.add('助手回复：\n${input.assistantText}');
    parts.add('只输出 JSON 数组。');
    return parts.join('\n\n');
  }
}

/// 解析与筛查。任何异常都退化为"少记"，绝不写入半成品。
class MemoryExtractionParser {
  const MemoryExtractionParser._();

  /// - [raw]：模型返回的原始文本（可能带 ```json 围栏或前后废话）
  /// - [sourceText]：本轮用户原话 + 助手回复，用于证据定位
  static MemoryScreenResult parse(String raw, {required String sourceText}) {
    final json = jsonArraySubstring(raw);
    if (json == null) return MemoryScreenResult();
    List<dynamic> decoded;
    try {
      final value = jsonDecode(json);
      if (value is! List) return MemoryScreenResult();
      decoded = value;
    } catch (_) {
      return MemoryScreenResult();
    }

    final candidates = <MemoryCandidate>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final content = (item['content'] as String?)?.trim() ?? '';
      if (content.isEmpty) continue;
      final evidence = ((item['evidence'] as String?) ?? '').trim();
      if (evidence.isEmpty) continue;

      final subject = MemoryGovernance.subjectFromValue(item['subject'] as String?);
      final resolved = MemoryGovernance.resolveScope(subject);
      final layer = MemoryLayer.fromValue((item['layer'] as String?)?.toLowerCase());
      // L1/L6/L7 不是抽取目标，落到语义层
      final persistedLayer = layer.persistsInMemories ? layer : MemoryLayer.semantic;
      final rawCategory = MemoryGovernance.normalizeCategory(
        (item['category'] as String?) ?? 'fact',
      );

      candidates.add(MemoryCandidate(
        scope: resolved.$1,
        layer: persistedLayer,
        category: rawCategory.isEmpty ? 'fact' : rawCategory,
        title: ((item['title'] as String?) ?? '').trim().isEmpty
            ? content.substring(0, content.length < 20 ? content.length : 20)
            : (item['title'] as String).trim(),
        content: content,
        evidenceQuote: evidence,
        importance: _clamp((item['importance'] as num?)?.toDouble() ?? 0.5),
        confidence: _clamp((item['confidence'] as num?)?.toDouble() ?? 0.6),
        scopeNeedsConfirmation: resolved.$2,
      ));
    }

    final screened = MemoryExtractionPolicy.instance.screen(
      candidates,
      sourceText: sourceText,
    );
    // 补全去重键，供落库时比对既有记忆
    for (final candidate in screened.accepted) {
      candidate.dedupeKey =
          MemoryExtractionPolicy.instance.normalizedDedupeKey(candidate);
    }
    return screened;
  }

  /// 从可能包含围栏/前后说明的文本里截取第一个 JSON 数组。
  static String? jsonArraySubstring(String raw) {
    final start = raw.indexOf('[');
    final end = raw.lastIndexOf(']');
    if (start < 0 || end < 0 || start >= end) return null;
    return raw.substring(start, end + 1);
  }

  static double _clamp(double value) {
    if (value.isNaN || value.isInfinite) return 0.5;
    return value.clamp(0.0, 1.0).toDouble();
  }
}

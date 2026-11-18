/// 记忆提取协调器（对齐 SwiftUI 版 MemoryExtractionCoordinator 的落库口径）。
///
/// 回复完成后异步执行：调用模型抽取结构化事实 → 筛查 → 路由：
/// - direct：直接写 memories（含 memory_sources 来源引用）；
/// - confirm：写 proposals，等用户确认（确认 UI 后续接入）。
/// 任何异常静默降级，不影响聊天主流程。
library;

import 'package:uuid/uuid.dart';

import '../core/memory/memory_extraction.dart';
import '../data/db/app_database.dart';
import '../data/repositories/memory_repository.dart';
import '../domain/models/memory.dart';
import 'openai_compatible_provider.dart';

class MemoryExtractionCoordinator {
  MemoryExtractionCoordinator(this._db);

  final AppDatabase _db;
  final Uuid _uuid = const Uuid();

  /// 使用与聊天相同的模型执行一次提取。
  Future<void> run({
    required OpenAICompatibleProvider provider,
    required MemoryRepository memories,
    required MemoryExtractionInput input,
    required String conversationId,
    required String userMessageId,
  }) async {
    try {
      final existing = await memories.list(limit: 20);
      final knownFacts = <String>[for (final record in existing) record.content];

      final completion = await provider.complete(<Map<String, String>>[
        <String, String>{'role': 'system', 'content': MemoryExtractionPrompt.system},
        <String, String>{
          'role': 'user',
          'content': MemoryExtractionPrompt.userMessage(
            MemoryExtractionInput(
              userText: input.userText,
              assistantText: input.assistantText,
              knownFacts: knownFacts,
            ),
          ),
        },
      ]);

      final sourceText = '${input.userText}\n${input.assistantText}';
      final screened = MemoryExtractionParser.parse(
        completion.content,
        sourceText: sourceText,
      );
      if (screened.accepted.isEmpty) return;

      final now = DateTime.now().millisecondsSinceEpoch;
      final policy = MemoryExtractionPolicy.instance;
      for (final candidate in screened.accepted) {
        final route = policy.route(candidate);
        if (route == MemoryWriteRoute.direct) {
          await _persistDirect(
            memories,
            candidate,
            now: now,
            conversationId: conversationId,
            userMessageId: userMessageId,
          );
        } else {
          await _persistProposal(candidate, now: now);
        }
      }
    } catch (_) {
      // 提取失败静默：少记总好过记错
    }
  }

  Future<void> _persistDirect(
    MemoryRepository memories,
    MemoryCandidate candidate, {
    required int now,
    required String conversationId,
    required String userMessageId,
  }) async {
    final record = MemoryRecord(
      id: _uuid.v4(),
      type: candidate.category,
      title: candidate.title,
      content: candidate.content,
      importance: _importanceText(candidate.importance),
      confidence: candidate.confidence,
      status: 'active',
      firstSeenAt: now,
      createdAt: now,
      updatedAt: now,
      scope: candidate.scope,
      layer: candidate.layer.value,
      category: candidate.category,
      sourceKind: 'real_interaction',
      epistemicStatus: 'observed',
      importanceScore: candidate.importance,
      importanceSource: 'extraction',
      importanceSourceAt: now,
      classificationStatus: 'confirmed',
      classifiedBy: 'extraction',
      classifiedAt: now,
    );
    final inserted = await memories.insert(record);
    if (inserted == null) return; // dedupe 命中：已有同键记忆
    // 来源引用：可按消息定位、可按来源清理
    await memories.addSource(
      memoryId: record.id,
      sourceType: 'chat_message',
      sourceId: userMessageId,
      excerpt: candidate.evidenceQuote,
      at: now,
    );
  }

  Future<void> _persistProposal(MemoryCandidate candidate, {required int now}) async {
    await _db.db.insert('proposals', <String, Object?>{
      'id': _uuid.v4(),
      'kind': 'memory_candidate',
      'payload_json': '{"scope":"${candidate.scope}",'
          '"layer":"${candidate.layer.value}",'
          '"category":"${candidate.category}",'
          '"title":"${_escape(candidate.title)}",'
          '"content":"${_escape(candidate.content)}",'
          '"evidence":"${_escape(candidate.evidenceQuote)}",'
          '"importance":${candidate.importance},'
          '"confidence":${candidate.confidence},'
          '"dedupe_key":"${candidate.dedupeKey ?? ''}"}',
      'reason': 'importance_or_scope',
      'evidence_json': candidate.evidenceQuote.isEmpty
          ? '[]'
          : '["${_escape(candidate.evidenceQuote)}"]',
      'status': 'pending',
      'created_at': now,
    });
  }

  static String _escape(String text) =>
      text.replaceAll('\\', r'\\').replaceAll('"', r'\"').replaceAll('\n', ' ');

  static String _importanceText(double score) {
    if (score >= 0.7) return 'high';
    if (score <= 0.3) return 'low';
    return 'normal';
  }
}

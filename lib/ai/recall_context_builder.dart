/// 记忆召回（与 SwiftUI 版 `RecallContextBuilder` 行为对齐）。
///
/// 把"关键词命中"扩展成"能支撑回答的过去上下文"：
/// 1. bigram 关键词命中（最相关，排最前）；
/// 1b. 导入的历史记忆（source_kind = astrbot_import 单独捞，避免重要度垫底被挤掉）；
/// 2. 命中为空或问句含回忆意图时启用兜底：
///    2a. 日记（由 [diaryLinesProvider] 提供，日记模块接入后注入）；
///    2b. 高显著度长期记忆；
///    2c. 真实聊天片段：本会话更早 + 其他会话历史。
///
/// 所有条目保留来源与时间，模型答不出来时应如实说"不确定"，不得编造。
library;

import '../core/time/current_time_context.dart';
import '../core/time/local_day.dart';
import '../data/db/app_database.dart';
import '../data/repositories/memory_repository.dart';
import '../domain/models/memory.dart';

/// 日记行提供者：日记模块（P1）接入后注入；P0 阶段传 null。
typedef DiaryLinesProvider = Future<List<String>> Function(DayRange? range);

class RecallContextBuilder {
  RecallContextBuilder(this._db, this._memories, {this.diaryLinesProvider});

  final AppDatabase _db;
  final MemoryRepository _memories;
  final DiaryLinesProvider? diaryLinesProvider;

  /// 触发"兜底召回"的问句特征词（与原版一致）。
  static const List<String> recallCues = <String>[
    '记得', '记不记得', '还记得', '记忆', '回忆', '想起',
    '以前', '之前', '上次', '上回', '那阵', '当时', '从前',
    '昨天', '前天', '上周', '上个月', '以前我们',
    '日记', '我们聊过', '你说过', '我说过', '发生过', '经历过',
    '一起去', '那一次', '那次',
  ];

  /// 组装注入提示词的记忆行。
  Future<List<String>> recall({
    required String query,
    String? currentConversationId,
    int limit = 12,
  }) async {
    final capped = limit.clamp(6, 24);
    final lines = <String>[];
    final seen = <String>{};

    void add(String line) {
      final normalized = line.trim();
      if (normalized.isEmpty || lines.length >= capped || seen.contains(normalized)) {
        return;
      }
      seen.add(normalized);
      lines.add(normalized);
    }

    // 1. 关键词命中：最相关，永远排在最前
    final hits = await _memories.search(query: query, limit: capped)
        .catchError((Object e) => <MemoryRecord>[]);
    for (final record in hits) {
      add(_memoryLine(record));
    }

    // 1b. 导入的历史记忆单独捞一批（按重要度排序它们永远垫底）
    if (hits.isEmpty) {
      for (final line in await _importedMemoryLines(limit: 5)) {
        add(line);
      }
    }

    // 2. 命中为空或明显在问过去 → 兜底召回
    final hasCue = hasRecallCue(query);
    if (hits.isNotEmpty && !hasCue) return lines;

    final range = CurrentTimeContext.resolveDayRange(query);

    // 2a. 日记
    final provider = diaryLinesProvider;
    if (provider != null) {
      try {
        for (final line in await provider(range)) {
          add(line);
        }
      } catch (_) {
        // 日记召回失败不阻断主流程
      }
    }

    // 2b. 高显著度长期记忆（候选放宽到 200，最多注入 10 条）
    final important = await _memories.list(limit: 200)
        .catchError((Object e) => <MemoryRecord>[]);
    var importantAdded = 0;
    for (final record in important) {
      if (importantAdded >= 10) break;
      final before = lines.length;
      add(_memoryLine(record));
      if (lines.length > before) importantAdded++;
    }

    // 2c. 真实聊天片段：本会话更早 + 其他会话历史
    for (final line in await _chatLines(
      currentConversationId: currentConversationId,
    )) {
      add(line);
    }

    return lines;
  }

  /// 导入记忆单独取一批：按重要度排序它们会永远垫底，必须按来源直查。
  Future<List<String>> _importedMemoryLines({required int limit}) async {
    final rows = await _db.db.rawQuery(
      'SELECT title, content, created_at FROM memories '
      'WHERE deleted_at IS NULL AND archived_at IS NULL '
      "AND source_kind = 'astrbot_import' "
      'ORDER BY importance_score DESC, created_at DESC LIMIT ?',
      <Object?>[limit.clamp(1, 30)],
    );
    return rows.map((row) {
      final title = (row['title'] ?? '') as String;
      final content = (row['content'] ?? '') as String;
      final millis = ((row['created_at'] ?? 0) as num).toInt();
      final day = dayKey(DateTime.fromMillisecondsSinceEpoch(millis));
      final body = content.isEmpty ? title : content;
      return '【导入记忆·$day】${clip(body, max: 110)}';
    }).toList();
  }

  static bool hasRecallCue(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    return recallCues.any(trimmed.contains);
  }

  static String _memoryLine(MemoryRecord record) {
    final body = record.content.isEmpty ? record.title : record.content;
    final tag = record.type.isEmpty ? '记忆' : record.type;
    return '[$tag] ${clip(body, max: 120)}';
  }

  static String clip(String text, {required int max}) {
    final flattened = text
        .replaceAll('\r\n', '\n')
        .replaceAll('\n', ' ')
        .trim();
    if (flattened.length <= max) return flattened;
    return '${flattened.substring(0, max)}…';
  }

  Future<List<String>> _chatLines({String? currentConversationId}) async {
    // 本地时区下"今天 00:00"对应的毫秒时间戳
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day)
        .millisecondsSinceEpoch;
    final lines = <String>[];

    // 本会话：今天之前的消息（"昨天聊过什么"）
    if (currentConversationId != null) {
      final rows = await _fetchMessages(
        conversationId: currentConversationId,
        beforeMillis: todayStart,
        limit: 10,
      );
      lines.addAll(rows.map(_chatLine));
    }

    // 其他会话：优先取今天之前的历史，避免又把"今晚"重复塞一遍
    final historical = await _fetchMessages(
      excluding: currentConversationId,
      beforeMillis: todayStart,
      limit: 14,
    );
    if (historical.isEmpty) {
      final latest = await _fetchMessages(
        excluding: currentConversationId,
        limit: 6,
      );
      lines.addAll(latest.map(_chatLine));
    } else {
      lines.addAll(historical.map(_chatLine));
    }
    return lines;
  }

  Future<List<Map<String, Object?>>> _fetchMessages({
    String? conversationId,
    String? excluding,
    int? beforeMillis,
    required int limit,
  }) async {
    return _db.db.rawQuery(
      'SELECT m.role AS role, m.text AS text, m.created_at AS created_at, '
      'c.title AS conversation_title '
      'FROM messages m JOIN conversations c ON c.id = m.conversation_id '
      'WHERE m.deleted_at IS NULL AND m.revoked_at IS NULL '
      "AND m.role IN ('user', 'assistant') "
      'AND m.origin <> \'system\' '
      'AND length(trim(m.text)) > 0 '
      'AND (? IS NULL OR m.conversation_id = ?) '
      'AND (? IS NULL OR m.conversation_id <> ?) '
      'AND (? IS NULL OR m.created_at < ?) '
      'ORDER BY m.created_at DESC, m.rowid DESC LIMIT ?',
      <Object?>[
        conversationId, conversationId,
        excluding, excluding,
        beforeMillis, beforeMillis,
        limit.clamp(1, 30),
      ],
    );
  }

  static String _chatLine(Map<String, Object?> row) {
    final role = (row['role'] ?? 'user') as String;
    final text = (row['text'] ?? '') as String;
    final millis = ((row['created_at'] ?? 0) as num).toInt();
    final title = (row['conversation_title'] ?? '') as String;
    final local = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int v) => v.toString().padLeft(2, '0');
    final time = '${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
    final speaker = role == 'user' ? '用户' : '我';
    return '【历史聊天·$time·$speaker·$title】${clip(text, max: 90)}';
  }
}

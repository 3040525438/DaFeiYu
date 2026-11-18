/// 每日日记自动生成（对齐 SwiftUI 版 DiaryAutoService.swift，W6 / D34 / D72）。
///
/// 硬约束（1:1 移植）：
/// - 只依据当天**真实存在**的消息生成，消息不足直接跳过，绝不编造经历；
/// - 模型输出必须是严格 JSON，解析失败一律不写库（宁可没有日记，也不写假日记）；
/// - 关系变化只作为观察写入，`relationship_change_confirmed` 恒为 false；
/// - 用户手写或编辑过的日记不覆盖；
/// - 核心人格只作为语气参考，不允许被日记改写。
library;

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../core/time/local_day.dart';
import '../data/db/app_database.dart';
import '../data/repositories/diary_repository.dart';
import '../domain/models/diary.dart';
import 'openai_compatible_provider.dart';

class DiaryAutoService {
  DiaryAutoService(this._database, this._diary);

  final AppDatabase _database;
  final DiaryRepository _diary;

  /// 参与生成的最小消息条数：至少要有一来一回
  static const int minimumMessageCount = 2;

  /// 送进提示词的最大字符数（超出后保留最早与最近两段）
  static const int maximumTranscriptCharacters = 6000;

  /// 为指定日期生成日记。`persona` 只影响语气，不参与事实。
  Future<DiaryReport> generate(
    String dayKey, {
    required OpenAICompatibleProvider provider,
    String persona = '',
    int maxTokens = 900,
  }) async {
    final messages = await _messages(on: dayKey);

    final hasUserContent = messages
        .any((Map<String, Object?> m) => (m['role'] as String?) == 'user' && ((m['text'] as String?) ?? '').length >= 2);
    if (messages.length < minimumMessageCount || !hasUserContent) {
      return DiaryReport(
        dayKey: dayKey,
        status: DiaryReportStatus.skippedNoContent,
        messageCount: messages.length,
        note: '当天有效聊天不足 $minimumMessageCount 条，不生成日记',
      );
    }

    // 用户手写 / 编辑过的日记一律不覆盖
    final existing = await _diary.entryByDate(dayKey);
    if (existing != null && existing.isProtectedFromAutoOverwrite) {
      return DiaryReport(
        dayKey: dayKey,
        status: DiaryReportStatus.skippedUserEdited,
        entryId: existing.id,
        messageCount: messages.length,
        note: '当天已有用户手写的日记，不覆盖',
      );
    }

    final transcript = _transcript(messages, limit: maximumTranscriptCharacters);
    final raw = await provider.complete(
      <Map<String, String>>[
        <String, String>{'role': 'system', 'content': systemPrompt},
        <String, String>{
          'role': 'user',
          'content': userPrompt(dayKey: dayKey, transcript: transcript, persona: persona),
        },
      ],
      extra: <String, Object?>{'temperature': 0.5, 'max_tokens': maxTokens},
    );

    final DiaryDraft draft;
    try {
      draft = _parse(raw.content);
    } catch (error) {
      return DiaryReport(
        dayKey: dayKey,
        status: DiaryReportStatus.failed,
        messageCount: messages.length,
        note: '模型输出不是可用的日记 JSON：$error',
      );
    }

    if (draft.skip) {
      return DiaryReport(
        dayKey: dayKey,
        status: DiaryReportStatus.skippedNoContent,
        messageCount: messages.length,
        note: '模型判断当天没有值得写入日记的内容',
      );
    }

    final content = draft.content.trim();
    if (content.isEmpty) {
      return DiaryReport(
        dayKey: dayKey,
        status: DiaryReportStatus.failed,
        messageCount: messages.length,
        note: '模型输出的日记正文为空',
      );
    }

    final existed = await _diary.entryByDate(dayKey) != null;
    final entry = await _diary.upsert(
      DiaryUpsert(
        entryDate: dayKey,
        title: draft.title,
        content: content,
        moodCode: draft.mood,
        source: 'auto',
        generatedBy: provider.modelId,
        isUserEdited: false,
        sharedExperience: draft.sharedExperience,
        observation: draft.observation,
        feeling: draft.feeling,
        relationshipChange: draft.relationshipChange,
        // 关系变化必须由用户确认，自动生成永远不置 true
        relationshipChangeConfirmed: false,
        changeReason: existed ? '自动重写当天日记' : '每日自动生成',
        changedBy: 'ai',
      ),
      atMillis: DateTime.now().millisecondsSinceEpoch,
    );

    return DiaryReport(
      dayKey: dayKey,
      status: existed ? DiaryReportStatus.updated : DiaryReportStatus.generated,
      entryId: entry.id,
      messageCount: messages.length,
      note: existed ? '已覆盖此前的自动日记' : '已生成当天日记',
    );
  }

  // ── 当天消息与转写 ─────────────────────────────────────────────────────────

  /// 当天（UTC+8 日界）真实存在的消息（软删除外）
  Future<List<Map<String, Object?>>> _messages({required String on}) async {
    final start = _dayStartMillis(on);
    if (start == null) return <Map<String, Object?>>[];
    final DatabaseExecutor exec = _database.db;
    return exec.query(
      'messages',
      columns: <String>['role', 'text', 'created_at', 'kind'],
      where: 'created_at >= ? AND created_at < ? AND deleted_at IS NULL',
      whereArgs: <Object?>[start, start + 86400000],
      orderBy: 'created_at ASC',
    );
  }

  static int? _dayStartMillis(String dayKey) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(dayKey);
    if (match == null) return null;
    return DateTime.utc(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      -8,
    ).millisecondsSinceEpoch;
  }

  /// 毫秒 → UTC+8 的 yyyy-MM-dd
  static String dayKeyFromMillis(int millis) {
    return dayKey(DateTime.fromMillisecondsSinceEpoch(millis + 8 * 3600 * 1000, isUtc: true));
  }

  /// `HH:mm 用户：xxx` / `HH:mm 大肥鱼：xxx`；超长保留最早与最近两段
  static String _transcript(List<Map<String, Object?>> messages, {required int limit}) {
    final lines = <String>[];
    String two(int v) => v.toString().padLeft(2, '0');
    for (final Map<String, Object?> message in messages) {
      final millis = (message['created_at'] as int?) ?? 0;
      final time = DateTime.fromMillisecondsSinceEpoch(millis + 8 * 3600 * 1000, isUtc: true);
      final clock = '${two(time.hour)}:${two(time.minute)}';
      final speaker = (message['role'] as String?) == 'user' ? '用户' : '大肥鱼';
      final text = ((message['text'] as String?) ?? '')
          .replaceAll('\r\n', '\n')
          .replaceAll('\n', ' ')
          .trim();
      if (text.isEmpty) continue;
      lines.add('$clock $speaker：$text');
    }

    final joined = lines.join('\n');
    if (joined.length <= limit) return joined;

    // 超长时保留最早与最近两段，中间明确标注省略，避免模型误以为中间不存在
    final headBudget = limit ~/ 2;
    final tailBudget = limit - headBudget;
    return '${joined.substring(0, headBudget)}\n…（中间省略）…\n${joined.substring(joined.length - tailBudget)}';
  }

  // ── 解析 ─────────────────────────────────────────────────────────────────

  /// 只允许界面认识的六个情绪码；其他一律丢弃，不猜
  static String? normalizeMood(String value) {
    const allowed = <String>{'calm', 'warm', 'happy', 'tired', 'low', 'excited'};
    final trimmed = value.trim().toLowerCase();
    return allowed.contains(trimmed) ? trimmed : null;
  }

  /// 从模型输出中提取首个 `{` 到末个 `}` 的 JSON（容忍 markdown 包裹）
  static Map<String, Object?> _extractJson(String raw) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw const FormatException('输出中不含 JSON 对象');
    }
    return jsonDecode(raw.substring(start, end + 1)) as Map<String, Object?>;
  }

  static DiaryDraft _parse(String raw) {
    final object = _extractJson(raw);
    String text(String key) => ((object[key] as String?) ?? '').trim();
    final skip = (object['skip'] as bool?) ?? false;
    if (skip) {
      return const DiaryDraft(
        skip: true, title: '', content: '', mood: '',
        sharedExperience: '', observation: '', feeling: '', relationshipChange: '',
      );
    }
    return DiaryDraft(
      skip: false,
      title: text('title').length > 40 ? text('title').substring(0, 40) : text('title'),
      content: text('content'),
      mood: text('mood'),
      sharedExperience: text('shared_experience'),
      observation: text('observation'),
      feeling: text('feeling'),
      relationshipChange: text('relationship_change'),
    );
  }

  // ── 提示词（与原版逐字一致）───────────────────────────────────────────────

  static const String systemPrompt = '''
你是"大肥鱼"的日记模块，负责把当天真实发生的聊天整理成一篇第一人称日记。
只输出一个 JSON 对象，不要输出解释、前后缀或 Markdown 代码块。

JSON 结构（键必须完全一致，不能增删改名）：
{"skip":false,"title":"...","content":"...","mood":"calm","shared_experience":"...","observation":"...","feeling":"...","relationship_change":"","relationship_change_confirmed":false}

约束：
1. 只能依据给定的当天聊天记录，不得虚构没发生过的事、没说过的话。
2. 记录不足以写成日记时，输出 {"skip":true}，其余字段留空。
3. content 是第一人称正文，80~300 字，按时间顺序概括当天真实经历。
4. shared_experience 写"我们一起做了什么"；observation 写注意到的细节与变化；
   feeling 写有依据的感受，不确定就写"说不清"或留空。
5. relationship_change 只在出现明确的关系变化迹象时才写，用中性描述（例如"她今天更愿意说自己的事"）；
   没有就留空。relationship_change_confirmed 永远为 false——关系变化必须由用户确认后才算数。
6. mood 只能取：calm / warm / happy / tired / low / excited。
7. 不得把推断写成用户明确表达过的事实；不得评价或修改核心人格。
''';

  static String userPrompt({required String dayKey, required String transcript, required String persona}) {
    final lines = <String>['【日期】$dayKey'];
    final trimmedPersona = persona.trim();
    if (trimmedPersona.isNotEmpty) {
      lines.add('【人格设定（只影响语气，不得修改）】');
      lines.add(trimmedPersona.length > 1200 ? trimmedPersona.substring(0, 1200) : trimmedPersona);
    }
    lines.add('【当天聊天记录】');
    lines.add(transcript);
    return lines.join('\n');
  }
}

/// 生成结果状态
enum DiaryReportStatus {
  generated,
  updated,
  skippedNoContent('skipped_no_content'),
  skippedUserEdited('skipped_user_edited'),
  failed;

  const DiaryReportStatus([this.wire]);
  final String? wire;

  String get value => wire ?? name;
}

/// 生成结果报告
class DiaryReport {
  DiaryReport({
    required this.dayKey,
    required this.status,
    this.entryId,
    required this.messageCount,
    required this.note,
  });

  final String dayKey;
  final DiaryReportStatus status;
  final String? entryId;
  final int messageCount;
  final String note;
}

/// 模型输出的日记草稿
class DiaryDraft {
  const DiaryDraft({
    required this.skip,
    required this.title,
    required this.content,
    required this.mood,
    required this.sharedExperience,
    required this.observation,
    required this.feeling,
    required this.relationshipChange,
  });

  final bool skip;
  final String title;
  final String content;
  final String mood;
  final String sharedExperience;
  final String observation;
  final String feeling;
  final String relationshipChange;
}

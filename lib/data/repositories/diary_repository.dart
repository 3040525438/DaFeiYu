/// 日记仓储（对齐 SwiftUI 版 GRDBDiaryRepository）。
///
/// 口径：
/// - upsert 按 entry_date 找当天日记（软删行不算），更新或插入；
/// - 每次写入追加 diary_entry_versions 全量快照；
/// - diary_fts 索引 = bigram(title + content + 四个结构化字段按行拼接)；
/// - 软删同步清 FTS。
library;

import 'package:uuid/uuid.dart';

import '../../core/text/bigram.dart';
import '../../domain/models/diary.dart';
import '../db/app_database.dart';

class DiaryRepository {
  DiaryRepository(this._db);

  final AppDatabase _db;
  final Uuid _uuid = const Uuid();

  static const List<String> _allowedEditors = <String>['user', 'ai', 'migration'];
  static const Set<String> _allowedMoods = <String>{
    'calm', 'warm', 'happy', 'tired', 'low', 'excited',
  };

  /// 写入（新增或按天覆盖），返回落库后的条目
  Future<DiaryEntry> upsert(DiaryUpsert request, {required int atMillis}) async {
    final content = request.content.trim();
    if (content.isEmpty) throw DiaryError.emptyContent;
    if (!_isValidDate(request.entryDate)) throw DiaryError.invalidDate(request.entryDate);
    if (!_allowedEditors.contains(request.changedBy)) {
      throw DiaryError.invalidEditor(request.changedBy);
    }
    final mood = request.moodCode?.trim().toLowerCase();
    final normalizedMood =
        (mood == null || mood.isEmpty || !_allowedMoods.contains(mood)) ? null : mood;

    final rows = await _db.db.query(
      'diary_entries',
      where: 'entry_date = ? AND deleted_at IS NULL',
      whereArgs: <Object?>[request.entryDate],
      limit: 1,
    );

    late String diaryId;
    if (rows.isNotEmpty) {
      diaryId = rows.first['id']! as String;
      await _db.db.execute(
        '''
        UPDATE diary_entries
        SET title = ?, content = ?, mood_code = ?, source = ?, generated_by = ?,
            is_user_edited = ?, memory_id = ?, shared_experience = ?, observation = ?,
            feeling = ?, relationship_change = ?, relationship_change_confirmed = ?,
            updated_at = ?
        WHERE id = ?
        ''',
        <Object?>[
          request.title, content, normalizedMood, request.source,
          request.generatedBy, request.isUserEdited ? 1 : 0,
          request.memoryId, request.sharedExperience, request.observation,
          request.feeling, request.relationshipChange,
          request.relationshipChangeConfirmed ? 1 : 0, atMillis, diaryId,
        ],
      );
    } else {
      diaryId = _uuid.v4();
      await _db.db.execute(
        '''
        INSERT INTO diary_entries
            (id, entry_date, title, content, mood_code, source, generated_by,
             is_user_edited, memory_id, shared_experience, observation, feeling,
             relationship_change, relationship_change_confirmed, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        <Object?>[
          diaryId, request.entryDate, request.title, content, normalizedMood,
          request.source, request.generatedBy, request.isUserEdited ? 1 : 0,
          request.memoryId, request.sharedExperience, request.observation,
          request.feeling, request.relationshipChange,
          request.relationshipChangeConfirmed ? 1 : 0, atMillis, atMillis,
        ],
      );
    }

    // 全量版本快照
    final versionRows = await _db.db.rawQuery(
      'SELECT COALESCE(MAX(version), 0) AS n FROM diary_entry_versions WHERE diary_id = ?',
      <Object?>[diaryId],
    );
    final nextVersion = ((versionRows.first['n'] as int?) ?? 0) + 1;
    await _db.db.execute(
      '''
      INSERT INTO diary_entry_versions
          (id, diary_id, version, title, content, change_reason, changed_by, created_at,
           shared_experience, observation, feeling, relationship_change,
           relationship_change_confirmed)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      <Object?>[
        _uuid.v4(), diaryId, nextVersion, request.title, content,
        request.changeReason, request.changedBy, atMillis,
        request.sharedExperience, request.observation, request.feeling,
        request.relationshipChange, request.relationshipChangeConfirmed ? 1 : 0,
      ],
    );

    await _index(diaryId, title: request.title, content: content, structured: <String>[
      request.sharedExperience, request.observation,
      request.feeling, request.relationshipChange,
    ]);

    final saved = await _db.db.query(
      'diary_entries',
      where: 'id = ?',
      whereArgs: <Object?>[diaryId],
      limit: 1,
    );
    return DiaryEntry.fromRow(saved.first);
  }

  Future<DiaryEntry?> entryById(String id) async {
    final rows = await _db.db.query(
      'diary_entries',
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : DiaryEntry.fromRow(rows.first);
  }

  Future<DiaryEntry?> entryByDate(String entryDate) async {
    final rows = await _db.db.query(
      'diary_entries',
      where: 'entry_date = ? AND deleted_at IS NULL',
      whereArgs: <Object?>[entryDate],
      limit: 1,
    );
    return rows.isEmpty ? null : DiaryEntry.fromRow(rows.first);
  }

  /// 日期区间（含端点）内的日记，按日期倒序
  Future<List<DiaryEntry>> entries(String fromKey, String toKey, {int limit = 30}) async {
    final rows = await _db.db.query(
      'diary_entries',
      where: 'entry_date >= ? AND entry_date <= ? AND deleted_at IS NULL',
      whereArgs: <Object?>[fromKey, toKey],
      orderBy: 'entry_date DESC',
      limit: limit.clamp(1, 200),
    );
    return rows.map(DiaryEntry.fromRow).toList();
  }

  Future<List<DiaryEntry>> recent({int limit = 60}) async {
    final rows = await _db.db.query(
      'diary_entries',
      where: 'deleted_at IS NULL',
      orderBy: 'entry_date DESC',
      limit: limit.clamp(1, 200),
    );
    return rows.map(DiaryEntry.fromRow).toList();
  }

  /// 软删（同步清 FTS）
  Future<void> softDelete(String id, {required int atMillis}) async {
    await _db.db.update(
      'diary_entries',
      <String, Object?>{'deleted_at': atMillis, 'updated_at': atMillis},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
    await _db.db.execute(
      'DELETE FROM diary_fts WHERE diary_id = ?',
      <Object?>[id],
    );
  }

  /// 确认某天日记中记录的关系变化（relationship_change_confirmed = 1）。
  ///
  /// 用户显式确认是关系变化生效的唯一入口（W6/D72 口径）；确认本身也写
  /// diary_entry_versions 快照留痕（changed_by='user'）。
  Future<DiaryEntry> confirmRelationshipChange(String id, {required int atMillis}) async {
    final rows = await _db.db.query(
      'diary_entries',
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) throw DiaryError.notFound;
    final entry = DiaryEntry.fromRow(rows.first);
    if (entry.relationshipChange.trim().isEmpty) {
      throw DiaryError('这条日记没有记录关系变化');
    }
    if (entry.relationshipChangeConfirmed) return entry;

    await _db.db.execute(
      'UPDATE diary_entries SET relationship_change_confirmed = 1, updated_at = ? '
      'WHERE id = ?',
      <Object?>[atMillis, id],
    );
    final versionRows = await _db.db.rawQuery(
      'SELECT COALESCE(MAX(version), 0) AS n FROM diary_entry_versions WHERE diary_id = ?',
      <Object?>[id],
    );
    final nextVersion = ((versionRows.first['n'] as int?) ?? 0) + 1;
    await _db.db.execute(
      '''
      INSERT INTO diary_entry_versions
          (id, diary_id, version, title, content, change_reason, changed_by, created_at,
           shared_experience, observation, feeling, relationship_change,
           relationship_change_confirmed)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      <Object?>[
        _uuid.v4(), id, nextVersion, entry.title, entry.content,
        '用户确认关系变化', 'user', atMillis,
        entry.sharedExperience, entry.observation, entry.feeling,
        entry.relationshipChange, 1,
      ],
    );
    return (await entryById(id)) ?? entry;
  }

  /// 召回钩子行（对齐原版 RecallContextBuilder.diaryLines）：
  /// `【日记·yyyy-MM-dd】共同经历：…；观察：…；感受：…`，结构化字段为空时退正文摘要。
  /// 按日期升序返回（时间顺序回顾）。
  Future<List<String>> recallLines(String fromKey, String toKey, {int limit = 5}) async {
    final entries = await this.entries(fromKey, toKey, limit: limit);
    entries.sort((DiaryEntry a, DiaryEntry b) => a.entryDate.compareTo(b.entryDate));
    return entries.map((DiaryEntry entry) {
      final parts = <String>[];
      if (entry.sharedExperience.trim().isNotEmpty) {
        parts.add('共同经历：${_clip(entry.sharedExperience, 80)}');
      }
      if (entry.observation.trim().isNotEmpty) {
        parts.add('观察：${_clip(entry.observation, 60)}');
      }
      if (entry.feeling.trim().isNotEmpty) {
        parts.add('感受：${_clip(entry.feeling, 60)}');
      }
      if (parts.isEmpty) {
        parts.add(_clip(entry.content, 120));
      }
      return '【日记·${entry.entryDate}】${parts.join('；')}';
    }).toList();
  }

  static String _clip(String text, int max) {
    final trimmed = text.trim();
    return trimmed.length <= max ? trimmed : trimmed.substring(0, max);
  }

  /// FTS 检索（与 memory_fts 口径一致：bigram token 加引号，AND 失败回退 OR，bm25 排序）
  Future<List<String>> search(String query, {int limit = 20}) async {
    final text = query.trim();
    if (text.isEmpty) return <String>[];
    final tokens = bigram(text).split(' ').where((String t) => t.isNotEmpty).toList();
    if (tokens.isEmpty) return <String>[];
    final quoted = tokens.map((String t) => '"$t"').toList();
    final andMatch = quoted.join(' AND ');
    final orMatch = quoted.join(' OR ');
    final cap = limit.clamp(1, 100);

    Future<List<String>> fetchIds(String match) async {
      final rows = await _db.db.rawQuery(
        '''
        SELECT diary_id FROM diary_fts
         WHERE diary_fts MATCH ?
         ORDER BY bm25(diary_fts)
         LIMIT ?
        ''',
        <Object?>[match, cap],
      );
      return rows.map((Map<String, Object?> r) => r['diary_id']! as String).toList();
    }

    var ids = await fetchIds(andMatch);
    if (ids.isEmpty && quoted.length > 1) {
      ids = await fetchIds(orMatch);
    }
    return ids;
  }

  Future<void> _index(String diaryId, {required String title, required String content, required List<String> structured}) async {
    final pieces = <String>[title, content, ...structured]
        .map((String piece) => piece.trim())
        .where((String piece) => piece.isNotEmpty)
        .toList();
    final merged = pieces.join('\n');
    if (merged.isEmpty) return;
    await _db.db.execute(
      'DELETE FROM diary_fts WHERE diary_id = ?',
      <Object?>[diaryId],
    );
    await _db.db.execute(
      'INSERT INTO diary_fts (diary_id, text_bigram) VALUES (?, ?)',
      <Object?>[diaryId, bigram(merged)],
    );
  }

  /// `yyyy-MM-dd` 合法性（含真实日期校验）
  bool _isValidDate(String text) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(text.trim());
    if (match == null) return false;
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    if (month < 1 || month > 12 || day < 1 || day > 31) return false;
    final normalized = DateTime(year, month, day);
    return normalized.year == year && normalized.month == month && normalized.day == day;
  }
}

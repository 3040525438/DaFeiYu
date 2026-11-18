/// 记忆仓储（与 SwiftUI 版 GRDBMemoryRepository 行为对齐）。
///
/// 检索口径：FTS5 memory_fts 虚表，bigram 由应用层生成（title + ' ' + content）；
/// 先 AND 精确匹配，零命中且 token > 1 时退回 OR + bm25 弱相关。
library;

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../core/text/bigram.dart';
import '../../domain/models/memory.dart';
import '../db/app_database.dart';

class MemoryRepository {
  MemoryRepository(this._db);

  final AppDatabase _db;

  /// 列表（排除已删除；[includeArchived] 为 false 时同时排除已归档）。
  Future<List<MemoryRecord>> list({
    String? scope,
    String? layer,
    bool includeArchived = false,
    int limit = 200,
    int offset = 0,
  }) async {
    final where = <String>['deleted_at IS NULL'];
    final args = <Object?>[];
    if (!includeArchived) {
      where.add('archived_at IS NULL');
    }
    if (scope != null) {
      where.add('scope = ?');
      args.add(scope);
    }
    if (layer != null) {
      where.add('layer = ?');
      args.add(layer);
    }
    final rows = await _db.db.query(
      'memories',
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'importance_score DESC, updated_at DESC',
      limit: limit.clamp(1, 500),
      offset: offset < 0 ? 0 : offset,
    );
    return rows.map(MemoryRecord.fromMap).toList();
  }

  Future<MemoryRecord?> byId(String id) async {
    final rows = await _db.db.query(
      'memories',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return MemoryRecord.fromMap(rows.first);
  }

  /// 新增记忆，并同步写入 FTS 索引。
  ///
  /// `dedupe_key` 唯一冲突（同 scope 下）视为重复，返回 null；
  /// 导入场景 `original_external_id` 唯一冲突同样返回 null。
  Future<String?> insert(MemoryRecord record) async {
    try {
      await _db.db.transaction((txn) async {
        await txn.insert('memories', record.toMap());
        await _upsertFts(txn, record);
      });
      return record.id;
    } on DatabaseException catch (e) {
      final message = e.toString();
      if (message.contains('memories.scope, memories.dedupe_key') ||
          message.contains('memories.import_batch_id, memories.original_external_id')) {
        return null;
      }
      rethrow;
    }
  }

  /// 更新记忆内容并重建 FTS 行；同时写入版本快照由调用方决定。
  Future<void> update(MemoryRecord record) async {
    await _db.db.transaction((txn) async {
      await txn.update(
        'memories',
        record.toMap(),
        where: 'id = ?',
        whereArgs: <Object?>[record.id],
      );
      await _upsertFts(txn, record);
    });
  }

  /// 归档（FTS 同步移除，召回不再命中）。
  Future<void> archive(String id, {required int at}) async {
    await _db.db.update(
      'memories',
      <String, Object?>{'archived_at': at},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
    await _db.db.delete('memory_fts', where: 'memory_id = ?', whereArgs: <Object?>[id]);
  }

  /// 软删除（FTS 同步移除）。
  Future<void> softDelete(String id, {required int at}) async {
    await _db.db.transaction((txn) async {
      await txn.update(
        'memories',
        <String, Object?>{'deleted_at': at},
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );
      await txn.delete('memory_fts', where: 'memory_id = ?', whereArgs: <Object?>[id]);
    });
  }

  /// 按来源软删除（导入覆盖场景），返回受影响条数。
  Future<int> softDeleteBySource({
    required String sourceType,
    required String sourceId,
    required int at,
  }) async {
    final rows = await _db.db.rawQuery(
      'SELECT DISTINCT memory_id FROM memory_sources '
      'WHERE source_type = ? AND source_id = ?',
      <Object?>[sourceType, sourceId],
    );
    var affected = 0;
    for (final row in rows) {
      final id = row['memory_id']! as String;
      await softDelete(id, at: at);
      affected++;
    }
    return affected;
  }

  /// 召回记录 + 更新召回统计（last_recalled_at / recall_count）。
  Future<void> recordRecall(
    String memoryId, {
    required int at,
    String? conversationId,
    String? messageId,
    String reason = 'retrieval',
    double score = 0,
    bool usedInPrompt = true,
  }) async {
    await _db.db.transaction((txn) async {
      await txn.insert('memory_recalls', <String, Object?>{
        'id': _newId(),
        'memory_id': memoryId,
        'at': at,
        'conversation_id': conversationId,
        'message_id': messageId,
        'reason': reason,
        'score': score,
        'used_in_prompt': usedInPrompt ? 1 : 0,
      });
      await txn.rawUpdate(
        'UPDATE memories SET last_recalled_at = ?, recall_count = recall_count + 1, '
        "heat = 'hot' WHERE id = ?",
        <Object?>[at, memoryId],
      );
    });
  }

  /// bigram 关键词检索：先 AND（精确），零命中且 token > 1 再 OR（弱相关，bm25 排序）。
  Future<List<MemoryRecord>> search({
    required String query,
    String? scope,
    int limit = 12,
  }) async {
    final tokens = bigram(query)
        .split(' ')
        .where((t) => t.isNotEmpty)
        .toList(growable: false);
    if (tokens.isEmpty) return [];
    final quoted = tokens.map((t) => '"$t"').toList(growable: false);
    final andMatch = quoted.join(' AND ');
    final orMatch = quoted.join(' OR ');
    final cap = limit.clamp(1, 200);

    Future<List<String>> fetchIds(String match) async {
      final rows = await _db.db.rawQuery(
        'SELECT memory_id FROM memory_fts '
        'WHERE memory_fts MATCH ? AND (? IS NULL OR scope = ?) '
        'ORDER BY bm25(memory_fts) ASC LIMIT ?',
        <Object?>[match, scope, scope, cap],
      );
      return rows.map((r) => r['memory_id']! as String).toList();
    }

    var ids = await fetchIds(andMatch);
    if (ids.isEmpty && quoted.length > 1) {
      ids = await fetchIds(orMatch);
    }
    if (ids.isEmpty) return [];

    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await _db.db.rawQuery(
      'SELECT * FROM memories WHERE id IN ($placeholders) AND deleted_at IS NULL',
      ids,
    );
    final byId = <String, MemoryRecord>{
      for (final row in rows)
        row['id']! as String: MemoryRecord.fromMap(row),
    };
    // 保持 bm25 排序
    return [
      for (final id in ids)
        if (byId[id] != null) byId[id]!,
    ];
  }

  /// 写入来源引用（UNIQUE(memory_id, source_type, source_id)，重复静默跳过）。
  Future<void> addSource({
    required String memoryId,
    required String sourceType,
    required String sourceId,
    String excerpt = '',
    int? at,
  }) async {
    try {
      await _db.db.insert('memory_sources', <String, Object?>{
        'id': _uuid.v4(),
        'memory_id': memoryId,
        'source_type': sourceType,
        'source_id': sourceId,
        'excerpt': excerpt,
        'at': at,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
    } on DatabaseException catch (e) {
      if (!e.toString().contains('ux_memory_sources')) rethrow;
    }
  }

  /// FTS 行写入（title + ' ' + content 生成 bigram）。
  Future<void> _upsertFts(DatabaseExecutor txn, MemoryRecord record) async {
    await txn.delete(
      'memory_fts',
      where: 'memory_id = ?',
      whereArgs: <Object?>[record.id],
    );
    await txn.insert('memory_fts', <String, Object?>{
      'memory_id': record.id,
      'scope': record.scope,
      'text_bigram': bigram('${record.title} ${record.content}'),
    });
  }

  final Uuid _uuid = const Uuid();

  String _newId() => _uuid.v4();
}

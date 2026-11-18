/// 消息仓储。
library;

import 'package:sqflite/sqflite.dart';

import '../../domain/models/message.dart';
import '../db/app_database.dart';

class MessageRepository {
  MessageRepository(this._db);

  final AppDatabase _db;

  /// 会话内可见消息（排除已删除与系统注入的隐藏指令），按时间正序。
  Future<List<Message>> list(String conversationId, {int limit = 500, int offset = 0}) async {
    final rows = await _db.db.query(
      'messages',
      where: 'conversation_id = ? AND deleted_at IS NULL '
          "AND NOT (role = 'user' AND origin = 'system')",
      whereArgs: <Object?>[conversationId],
      orderBy: 'created_at ASC, rowid ASC',
      limit: limit,
      offset: offset,
    );
    return rows.map(Message.fromMap).toList();
  }

  Future<Message?> byId(String id) async {
    final rows = await _db.db.query(
      'messages',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Message.fromMap(rows.first);
  }

  /// 幂等写入：`client_uuid` 唯一冲突时返回 false（重复消息）。
  Future<bool> insert(Message message) async {
    try {
      await _db.db.insert('messages', message.toMap());
      return true;
    } on DatabaseException catch (e) {
      if (e.toString().contains('UNIQUE constraint failed: messages.client_uuid')) {
        return false;
      }
      rethrow;
    }
  }

  /// 覆盖式写入（按 id 替换），用于状态机流转（sending → sent/failed/canceled）。
  Future<void> update(Message message) async {
    await _db.db.update(
      'messages',
      message.toMap(),
      where: 'id = ?',
      whereArgs: <Object?>[message.id],
    );
  }

  /// 软删除。
  Future<void> softDelete(String id, {required int at}) async {
    await _db.db.update(
      'messages',
      <String, Object?>{'deleted_at': at},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> setFavorite(String id, bool favorite) async {
    await _db.db.update(
      'messages',
      <String, Object?>{'is_favorite': favorite ? 1 : 0},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> setImportant(String id, bool important, {required int at}) async {
    await _db.db.update(
      'messages',
      <String, Object?>{'is_important': important ? 1 : 0, 'important_at': important ? at : null},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<int> count(String conversationId) async {
    final result = await _db.db.rawQuery(
      'SELECT COUNT(*) AS c FROM messages '
      'WHERE conversation_id = ? AND deleted_at IS NULL',
      <Object?>[conversationId],
    );
    return (result.first['c'] as num?)?.toInt() ?? 0;
  }
}

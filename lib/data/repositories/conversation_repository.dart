/// 会话仓储。
library;

import 'package:sqflite/sqflite.dart';

import '../../domain/models/conversation.dart';
import '../db/app_database.dart';

class ConversationRepository {
  ConversationRepository(this._db);

  final AppDatabase _db;

  /// 按更新时间倒序列出未归档会话。
  Future<List<Conversation>> list({bool includeArchived = false}) async {
    final rows = await _db.db.query(
      'conversations',
      where: includeArchived ? null : 'archived_at IS NULL',
      orderBy: 'updated_at DESC',
    );
    return rows.map(Conversation.fromMap).toList();
  }

  Future<Conversation?> byId(String id) async {
    final rows = await _db.db.query(
      'conversations',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Conversation.fromMap(rows.first);
  }

  /// 幂等写入（同 id 覆盖）。
  Future<void> upsert(Conversation conversation) async {
    await _db.db.insert(
      'conversations',
      conversation.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> touch(String id, {int? updatedAt}) async {
    await _db.db.update(
      'conversations',
      <String, Object?>{'updated_at': updatedAt ?? DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> archive(String id, {required int at}) async {
    await _db.db.update(
      'conversations',
      <String, Object?>{'archived_at': at},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> unarchive(String id) async {
    await _db.db.rawUpdate(
      'UPDATE conversations SET archived_at = NULL WHERE id = ?',
      <Object?>[id],
    );
  }

  /// 删除会话（消息级联删除由外键完成；需打开 foreign_keys）。
  Future<void> delete(String id) async {
    await _db.db.delete('conversations', where: 'id = ?', whereArgs: <Object?>[id]);
  }
}

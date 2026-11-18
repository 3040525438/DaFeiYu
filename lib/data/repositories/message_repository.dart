/// 消息仓储。
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
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

  // ── 图片附件（P1 图片理解入口的数据层）────────────────────────────────────

  /// 把图片挂到消息上：复制进 `<db 目录>/attachments/`，
  /// 写 attachments（sha256 幂等）+ message_attachments，并把消息标记为 image。
  /// 返回附件的 rel_path（发送给模型时用）。
  Future<String> attachImageToMessage(String messageId, String sourcePath) async {
    final source = File(sourcePath);
    if (!source.existsSync()) {
      throw Exception('图片不存在：$sourcePath');
    }
    final bytes = await source.readAsBytes();
    final hash = sha256.convert(bytes).toString();

    final dbDir = File(_db.db.path).parent.path;
    final dir = Directory('$dbDir/attachments');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final relPath = 'attachments/$hash${_extensionOf(sourcePath)}';
    final target = File('$dbDir/$relPath');
    if (!target.existsSync()) {
      await source.copy(target.path);
    }

    // 同一哈希只登记一份附件
    await _db.db.insert(
      'attachments',
      <String, Object?>{
        'id': hash,
        'sha256': hash,
        'kind': 'image',
        'rel_path': relPath,
        'byte_size': bytes.length,
        'mime': _mimeOf(sourcePath),
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    await _db.db.insert(
      'message_attachments',
      <String, Object?>{'message_id': messageId, 'attachment_id': hash, 'sort': 0},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    await _db.db.execute(
      "UPDATE messages SET kind = 'image' WHERE id = ?",
      <Object?>[messageId],
    );
    return relPath;
  }

  /// 消息的图片附件绝对路径列表（按 sort 排序）。
  Future<List<String>> imagePathsForMessage(String messageId) async {
    final rows = await _db.db.rawQuery(
      '''
      SELECT a.rel_path FROM message_attachments ma
      JOIN attachments a ON a.id = ma.attachment_id
      WHERE ma.message_id = ?
      ORDER BY ma.sort ASC
      ''',
      <Object?>[messageId],
    );
    final dbDir = File(_db.db.path).parent.path;
    return rows
        .map((Map<String, Object?> row) => (row['rel_path'] as String?) ?? '')
        .where((String rel) => rel.isNotEmpty)
        .map((String rel) => '$dbDir/$rel')
        .toList();
  }

  String _extensionOf(String path) {
    final name = path.replaceAll('\\', '/').split('/').last;
    final index = name.lastIndexOf('.');
    return index <= 0 ? '.png' : name.substring(index).toLowerCase();
  }

  String _mimeOf(String path) {
    final ext = _extensionOf(path);
    return switch (ext) {
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.webp' => 'image/webp',
      '.gif' => 'image/gif',
      _ => 'image/png',
    };
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

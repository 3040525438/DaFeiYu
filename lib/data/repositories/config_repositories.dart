/// 模型配置与人格读写。
library;

import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../domain/models/model_config.dart';
import '../../domain/models/persona.dart';
import '../db/app_database.dart';

class ModelConfigRepository {
  ModelConfigRepository(this._db);

  final AppDatabase _db;

  /// 默认配置（is_default = 1）；不存在时取第一条。
  Future<ModelConfig?> defaultConfig() async {
    var rows = await _db.db.query(
      'model_configs',
      where: 'is_default = 1',
      limit: 1,
    );
    if (rows.isEmpty) {
      rows = await _db.db.query('model_configs', limit: 1);
    }
    if (rows.isEmpty) return null;
    return ModelConfig.fromMap(rows.first);
  }

  Future<List<ModelConfig>> list() async {
    final rows = await _db.db.query('model_configs', orderBy: 'created_at DESC');
    return rows.map(ModelConfig.fromMap).toList();
  }

  Future<void> upsert(ModelConfig config) async {
    await _db.db.transaction((txn) async {
      await txn.insert(
        'model_configs',
        config.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      if (config.isDefault) {
        await txn.rawUpdate(
          'UPDATE model_configs SET is_default = 0 WHERE id != ?',
          <Object?>[config.id],
        );
      }
    });
  }

  Future<void> delete(String id) async {
    await _db.db.delete('model_configs', where: 'id = ?', whereArgs: <Object?>[id]);
  }
}

class PersonaRepository {
  PersonaRepository(this._db);

  final AppDatabase _db;

  /// 核心人格条目（persona kind = 'core' 的全部 items）。
  Future<Persona?> corePersona() async {
    final rows = await _db.db.query(
      'personas',
      where: "kind = 'core'",
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final personaRow = rows.first;
    final personaId = personaRow['id']! as String;
    final items = await _db.db.query(
      'persona_items',
      where: 'persona_id = ?',
      whereArgs: <Object?>[personaId],
      orderBy: 'section ASC, key ASC',
    );
    return Persona.fromMaps(personaRow, items);
  }

  /// 核心人格系统提示词（persona_items section='核心' key='system_prompt'）。
  Future<String?> coreSystemPrompt() async {
    final rows = await _db.db.rawQuery(
      'SELECT pi.value FROM persona_items pi '
      'JOIN personas p ON p.id = pi.persona_id '
      "WHERE p.kind = 'core' AND pi.section = '核心' AND pi.key = 'system_prompt' "
      'LIMIT 1',
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  /// 保存核心人格系统提示词（section='核心' key='system_prompt'）。
  ///
  /// - 无核心人格时创建占位（与 AstrBot 导入的「首启占位人格」识别口径一致）；
  /// - 每次保存追加 persona_versions 全量快照，current_version 同步递增。
  Future<void> saveCoreSystemPrompt(String prompt, {required int atMillis}) async {
    final trimmed = prompt.trim();
    if (trimmed.isEmpty) throw ArgumentError('系统提示词不能为空');
    const uuid = Uuid();
    await _db.db.transaction((txn) async {
      final rows = await txn.query('personas', where: "kind = 'core'", limit: 1);
      String personaId;
      if (rows.isEmpty) {
        personaId = uuid.v4();
        await txn.insert('personas', <String, Object?>{
          'id': personaId,
          'kind': 'core',
          'name': '大肥鱼',
          'is_locked': 0,
          'current_version': 1,
          'created_at': atMillis,
          'updated_at': atMillis,
        });
      } else {
        personaId = rows.first['id']! as String;
      }

      final itemRows = await txn.query(
        'persona_items',
        where: "persona_id = ? AND section = '核心' AND key = 'system_prompt'",
        whereArgs: <Object?>[personaId],
        limit: 1,
      );
      if (itemRows.isEmpty) {
        await txn.insert('persona_items', <String, Object?>{
          'id': uuid.v4(),
          'persona_id': personaId,
          'section': '核心',
          'key': 'system_prompt',
          'value': trimmed,
          'source': 'user',
          'updated_at': atMillis,
        });
      } else {
        await txn.update(
          'persona_items',
          <String, Object?>{'value': trimmed, 'updated_at': atMillis},
          where: 'id = ?',
          whereArgs: <Object?>[itemRows.first['id']],
        );
      }

      final versionRows = await txn.rawQuery(
        'SELECT COALESCE(MAX(version), 0) AS n FROM persona_versions WHERE persona_id = ?',
        <Object?>[personaId],
      );
      final nextVersion = ((versionRows.first['n'] as int?) ?? 0) + 1;
      await txn.insert('persona_versions', <String, Object?>{
        'id': uuid.v4(),
        'persona_id': personaId,
        'version': nextVersion,
        'snapshot_json': jsonEncode(<String, String?>{'system_prompt': trimmed}),
        'change_reason': '用户编辑核心人格',
        'changed_by': 'user',
        'created_at': atMillis,
      });
      await txn.rawUpdate(
        'UPDATE personas SET current_version = ?, updated_at = ? WHERE id = ?',
        <Object?>[nextVersion, atMillis, personaId],
      );
    });
  }
}

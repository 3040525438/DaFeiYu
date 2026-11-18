/// 模型配置与人格读取。
library;

import 'package:sqflite/sqflite.dart';

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
}

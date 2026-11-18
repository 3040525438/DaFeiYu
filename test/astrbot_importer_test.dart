/// AstrBot 导入器单测：造源库 → 预演不落库 → 正式导入 → 重复去重 →
/// 覆盖式导入（先回滚旧批次）→ 回滚。
library;

import 'dart:io';

import 'package:dafeiyu_flutter/core/import/astrbot_import.dart';
import 'package:dafeiyu_flutter/core/import/astrbot_importer.dart';
import 'package:dafeiyu_flutter/data/db/app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  late AstrBotImporter importer;
  late String tempDir;

  setUp(() async {
    db = await AppDatabase.open(':memory:');
    importer = AstrBotImporter(db);
    tempDir =
        await Directory.systemTemp.createTemp('dafeiyu-astrbot-test').then((Directory d) => d.path);
  });

  tearDown(() async {
    await db.close();
    final dir = Directory(tempDir);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// 造一个 AstrBot 聊天源库（chat_memory_records）
  Future<String> buildChatSource(String fileName) async {
    final path = '$tempDir${Platform.pathSeparator}$fileName';
    final source = await openDatabase(path, version: 1, onCreate: (Database sdb, int _) async {
      await sdb.execute('''
        CREATE TABLE chat_memory_records (
          id INTEGER PRIMARY KEY,
          umo TEXT, conversation_id TEXT, platform_name TEXT,
          raw_timestamp REAL, created_at TEXT, role TEXT,
          content_kind TEXT, content TEXT, message_id TEXT, reply_id TEXT,
          recalled_at TEXT, deleted_at TEXT
        )
      ''');
      await sdb.execute('''
        CREATE TABLE chat_memory_tool_records (id INTEGER PRIMARY KEY, payload TEXT)
      ''');
      await sdb.insert('chat_memory_records', <String, Object?>{
        'id': 1,
        'umo': 'qq:user1',
        'conversation_id': 'conv-a',
        'platform_name': 'QQ',
        'raw_timestamp': 1760000000.0,
        'role': 'user',
        'content_kind': '[]',
        'content': '今天钓到了一条大鱼',
        'message_id': 'p1',
      });
      await sdb.insert('chat_memory_records', <String, Object?>{
        'id': 2,
        'umo': 'qq:user1',
        'conversation_id': 'conv-a',
        'platform_name': 'QQ',
        'raw_timestamp': 1760000060.0,
        'role': 'assistant',
        'content_kind': '[]',
        'content': '真厉害！',
        'message_id': 'p2',
        'reply_id': 'p1',
      });
      await sdb.insert('chat_memory_records', <String, Object?>{
        'id': 3,
        'umo': 'qq:user1',
        'conversation_id': 'conv-a',
        'platform_name': 'QQ',
        'raw_timestamp': 1760000120.0,
        'role': 'system',
        'content_kind': '[]',
        'content': '未知角色的行',
        'message_id': 'p3',
      });
      await sdb.insert('chat_memory_records', <String, Object?>{
        'id': 4,
        'umo': 'qq:user1',
        'conversation_id': 'conv-a',
        'platform_name': 'QQ',
        'raw_timestamp': 1760000180.0,
        'role': 'user',
        'content_kind': '["image"]',
        'content': '[图片]',
        'message_id': 'p4',
      });
      await sdb.insert('chat_memory_tool_records', <String, Object?>{
        'id': 1,
        'payload': 'tool',
      });
    });
    await source.close();
    return path;
  }

  /// 造一个 AstrBot 长期记忆源库（mem 表）
  Future<String> buildMemorySource(String fileName) async {
    final path = '$tempDir${Platform.pathSeparator}$fileName';
    final source = await openDatabase(path, version: 1, onCreate: (Database sdb, int _) async {
      await sdb.execute('CREATE TABLE mem (id INTEGER PRIMARY KEY, kind TEXT, day TEXT, text TEXT, sig TEXT)');
      await sdb.insert('mem', <String, Object?>{
        'id': 1,
        'kind': 'fact',
        'day': '2025-10-09',
        'text': '用户住在杭州',
        'sig': 'sig-1',
      });
      await sdb.insert('mem', <String, Object?>{
        'id': 2,
        'kind': 'fact',
        'day': 'FACTS',
        'text': '用户怕猫',
        'sig': 'sig-2',
      });
    });
    await source.close();
    return path;
  }

  /// 造一个 AstrBot 人格源库（personas 表）
  Future<String> buildPersonaSource(String fileName, {required String systemPrompt}) async {
    final path = '$tempDir${Platform.pathSeparator}$fileName';
    final source = await openDatabase(path, version: 1, onCreate: (Database sdb, int _) async {
      await sdb.execute(
        'CREATE TABLE personas (id INTEGER PRIMARY KEY, persona_id TEXT, system_prompt TEXT, begin_dialogs TEXT)',
      );
      await sdb.insert('personas', <String, Object?>{
        'id': 1,
        'persona_id': 'astrbot-p1',
        'system_prompt': systemPrompt,
        'begin_dialogs': null,
      });
    });
    await source.close();
    return path;
  }

  Future<int> count(String table) async {
    final rows = await db.db.rawQuery('SELECT count(*) AS n FROM $table');
    return (rows.first['n'] as int?) ?? 0;
  }

  test('无源报错', () async {
    expect(
      () => importer.run(const AstrBotSourcePaths(), const AstrBotImportOptions()),
      throwsA(isA<AstrBotImportError>()),
    );
  });

  test('预演：完整跑通校验但业务表零写入', () async {
    final chat = await buildChatSource('chat.db');
    final report = await importer.run(
      AstrBotSourcePaths(chatMemoryDatabase: chat),
      const AstrBotImportOptions(isDryRun: true),
    );

    expect(report.status, AstrBotImportStatus.dryRunSucceeded);
    // 覆盖校验：源 4 = 新增 3（p1/p2 正常 + p4 图片本体照常导入）+ 待处理 1（p3 未知角色）
    // 与原版口径一致：媒体缺失的行记 pending 但消息本体仍导入
    expect(report.counts.sourceChatRecords, 4);
    expect(report.counts.messagesNew, 3);
    expect(report.counts.messagesPending, 1);
    expect(report.counts.pendingToolRecords, 1);
    expect(report.pendingByReason['unknown_role'], 1);
    expect(report.pendingByReason['media_missing'], 1);

    // 业务表零写入（dry run），只留批次与 pending
    expect(await count('conversations'), 0);
    expect(await count('messages'), 0);
    expect(await count('astrbot_migration_batches'), 1);
  });

  test('正式导入：会话/消息/记忆/人格入库，FTS 回填，再导一次去重', () async {
    final chat = await buildChatSource('chat.db');
    final mem = await buildMemorySource('memory.db');
    final persona = await buildPersonaSource('data_v4.db', systemPrompt: '你是大肥鱼');

    // 先放一个"占位核心人格"，导入应原位替换
    await db.db.execute(
      'INSERT INTO personas (id, kind, name, is_locked, current_version, created_at, updated_at) '
      "VALUES ('core-uuid', 'core', '占位核心人格', 1, 1, 0, 0)",
    );
    await db.db.execute(
      'INSERT INTO persona_items (id, persona_id, section, key, value, confidence, weight, source, updated_at, tier, tier_status, tier_source, tier_evidence, status) '
      "VALUES ('item-uuid', 'core-uuid', '核心', 'system_prompt', '占位核心人格', 1.0, 1.0, 'default', 0, 'core', 'core', 'default', '{}', 'active')",
    );

    final report = await importer.run(
      AstrBotSourcePaths(
        chatMemoryDatabase: chat,
        longTermMemoryDatabase: mem,
        personaDatabase: persona,
      ),
      const AstrBotImportOptions(isDryRun: false, replacesCorePersona: true),
    );

    expect(report.status, AstrBotImportStatus.succeeded);
    expect(report.counts.messagesNew, 3);
    expect(report.counts.memoriesNew, 1); // sig-1；sig-2 日期非法进待处理
    expect(report.counts.memoriesPending, 1);
    expect(report.counts.personaRowsImported, 1);

    // 会话与消息
    final convs = await db.db.query('conversations');
    expect(convs.length, 1);
    expect(convs.first['kind'], 'imported');
    expect(await count('messages'), 3);
    // 回复关系已接上
    final reply = await db.db.query(
      'messages',
      columns: <String>['reply_to_id'],
      where: "client_uuid = 'astrbot:chat:2'",
    );
    expect((reply.first['reply_to_id'] as String?) ?? '', 'astrbot-msg-1');
    // 会话时间已对齐到最后一条消息
    final convUpdatedAt = convs.first['updated_at'] as int?;
    expect(convUpdatedAt, greaterThanOrEqualTo(1760000120000));

    // 记忆 + FTS
    expect(await count('memories'), 1);
    final fts = await db.db.rawQuery(
      "SELECT count(*) AS n FROM memory_fts WHERE memory_id LIKE 'astrbot-mem-%'",
    );
    expect((fts.first['n'] as int?) ?? 0, 1);

    // 人格原位替换：还是同一个 id，值已换成 AstrBot 的
    final personaItems = await db.db.query('persona_items', where: "key = 'system_prompt'");
    expect(personaItems.first['persona_id'], 'core-uuid');
    expect(personaItems.first['value'], '你是大肥鱼');
    expect(personaItems.first['source'], 'astrbot');
    final versions = await db.db.query('persona_versions', where: "persona_id = 'core-uuid'");
    expect(versions.length, 1);

    // 再次导入：全部重复，不重复累积
    final report2 = await importer.run(
      AstrBotSourcePaths(
        chatMemoryDatabase: chat,
        longTermMemoryDatabase: mem,
      ),
      const AstrBotImportOptions(isDryRun: false),
    );
    expect(report2.counts.messagesNew, 0);
    expect(report2.counts.messagesDuplicate, 3);
    expect(report2.counts.memoriesNew, 0);
    expect(report2.counts.memoriesDuplicate, 1);
    expect(await count('messages'), 3);
    expect(await count('memories'), 1);
  });

  test('覆盖式导入：replacesPreviousImports 先回滚旧批次再导入', () async {
    final chat = await buildChatSource('chat.db');
    await importer.run(
      AstrBotSourcePaths(chatMemoryDatabase: chat),
      const AstrBotImportOptions(isDryRun: false),
    );
    expect(await count('messages'), 3);

    // 改源：删除全部消息（模拟源库被清空），覆盖式导入后应只剩本批数据（0 条）
    final chatPath = '$tempDir${Platform.pathSeparator}chat2.db';
    final source2 = await openDatabase(chatPath, version: 1, onCreate: (Database sdb, int _) async {
      await sdb.execute('''
        CREATE TABLE chat_memory_records (
          id INTEGER PRIMARY KEY, umo TEXT, conversation_id TEXT, platform_name TEXT,
          raw_timestamp REAL, created_at TEXT, role TEXT,
          content_kind TEXT, content TEXT, message_id TEXT, reply_id TEXT,
          recalled_at TEXT, deleted_at TEXT
        )
      ''');
    });
    await source2.close();

    final report = await importer.run(
      AstrBotSourcePaths(chatMemoryDatabase: chatPath),
      const AstrBotImportOptions(isDryRun: false, replacesPreviousImports: true),
    );
    expect(report.status, AstrBotImportStatus.succeeded);
    expect(await count('messages'), 0);
    // 旧批次已被标记回滚
    final batches = await importer.batches();
    expect(batches.where((AstrBotBatchSummary b) => b.status == AstrBotImportStatus.rolledBack.value).length, 1);
  });

  test('回滚：只删本批次造出的数据', () async {
    final chat = await buildChatSource('chat.db');
    await db.db.execute(
      'INSERT INTO conversations (id, title, kind, created_at, updated_at) '
      "VALUES ('own-conv', '本机会话', 'main', 0, 0)",
    );

    final report = await importer.run(
      AstrBotSourcePaths(chatMemoryDatabase: chat),
      const AstrBotImportOptions(isDryRun: false),
    );
    expect(await count('messages'), 3);

    final rollback = await importer.rollback(report.batchId, atMillis: 999);
    expect(rollback.deletedMessages, 3);
    expect(rollback.deletedConversations, 1);
    expect(await count('messages'), 0);
    // 本机数据不受影响
    final own = await db.db.query('conversations', where: "id = 'own-conv'");
    expect(own.length, 1);
    // 映射与待处理区已清空
    expect(await count('astrbot_id_map'), 0);
    expect(await count('astrbot_import_pending'), 0);
  });
}

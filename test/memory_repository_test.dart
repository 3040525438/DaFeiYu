/// 记忆层单测：schema 建表、FTS 检索（AND → OR 回退）、软删除、召回记录。
library;

import 'package:dafeiyu_flutter/ai/recall_context_builder.dart';
import 'package:dafeiyu_flutter/core/time/current_time_context.dart';
import 'package:dafeiyu_flutter/data/db/app_database.dart';
import 'package:dafeiyu_flutter/data/repositories/memory_repository.dart';
import 'package:dafeiyu_flutter/domain/models/memory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  late MemoryRepository repo;

  setUp(() async {
    db = await AppDatabase.open(':memory:');
    repo = MemoryRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  MemoryRecord makeRecord({
    required String id,
    required String title,
    required String content,
    String scope = 'shared',
    String sourceKind = 'real_interaction',
    double? importanceScore,
    String? dedupeKey,
    String? originalExternalId,
    String importBatchId = 'batch-1',
  }) {
    return MemoryRecord(
      id: id,
      type: '事实',
      title: title,
      content: content,
      firstSeenAt: 1700000000000,
      createdAt: 1700000000000,
      updatedAt: 1700000000000,
      scope: scope,
      sourceKind: sourceKind,
      importanceScore: importanceScore,
      dedupeKey: dedupeKey,
      originalExternalId: originalExternalId,
      importBatchId: importBatchId,
    );
  }

  test('全量建表通过（含 FTS5 与视图）', () async {
    final tables = await db.db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
    );
    final names = tables.map((r) => r['name'] as String).toSet();
    expect(names, containsAll(<String>[
      'memories', 'memory_scopes', 'memory_fts', 'memory_recalls',
      'episodes', 'entities', 'kg_nodes', 'memory_jobs',
    ]));
    final views = await db.db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'view'",
    );
    final viewNames = views.map((r) => r['name'] as String).toSet();
    expect(
      viewNames,
      containsAll(<String>['v_memory_user', 'v_memory_shared', 'v_memory_self', 'v_memory_stats']),
    );
    // 预置三套记忆
    final scopes = await db.db.query('memory_scopes');
    expect(scopes.length, 3);
  });

  test('insert 写入 FTS，search 按关键词命中', () async {
    await repo.insert(makeRecord(
      id: 'm1',
      title: '喜欢的食物',
      content: '用户喜欢吃火锅，尤其是麻辣锅底',
    ));
    await repo.insert(makeRecord(
      id: 'm2',
      title: '工作情况',
      content: '用户在一家互联网公司做后端开发',
    ));

    final hits = await repo.search(query: '火锅', limit: 10);
    expect(hits.map((m) => m.id).toList(), ['m1']);

    // AND 精确：两词同时出现才命中
    final andHits = await repo.search(query: '喜欢吃火锅');
    expect(andHits.map((m) => m.id).toList(), ['m1']);

    // OR 回退：长句只含部分词也能捞到
    final orHits = await repo.search(query: '火锅 后端开发');
    expect(orHits.map((m) => m.id).toSet(), <String>{'m1', 'm2'});

    // 无命中
    final none = await repo.search(query: '量子力学');
    expect(none, isEmpty);
  });

  test('dedupe_key 冲突返回 null（同 scope 幂等）', () async {
    final first = await repo.insert(makeRecord(
      id: 'm1', title: '生日', content: '用户生日是 3 月 5 日', dedupeKey: 'birthday-0305',
    ));
    expect(first, 'm1');
    final dup = await repo.insert(makeRecord(
      id: 'm2', title: '生日重复', content: '再次记录生日', dedupeKey: 'birthday-0305',
    ));
    expect(dup, isNull);
  });

  test('original_external_id 冲突返回 null（导入幂等）', () async {
    final first = await repo.insert(makeRecord(
      id: 'm1', title: '导入记忆', content: '旧数据 1', originalExternalId: 'ext-1',
    ));
    expect(first, 'm1');
    final dup = await repo.insert(makeRecord(
      id: 'm2', title: '导入记忆重复', content: '旧数据 1 再次导入', originalExternalId: 'ext-1',
    ));
    expect(dup, isNull);
  });

  test('softDelete 后 FTS 不再命中', () async {
    await repo.insert(makeRecord(id: 'm1', title: '宠物', content: '用户养了一只橘猫'));
    await repo.softDelete('m1', at: 1700000001000);
    final hits = await repo.search(query: '橘猫');
    expect(hits, isEmpty);
    final record = await repo.byId('m1');
    expect(record!.deletedAt, 1700000001000);
  });

  test('recordRecall 更新统计并写入 memory_recalls', () async {
    await repo.insert(makeRecord(id: 'm1', title: '约定', content: '周末一起看电影'));
    await repo.recordRecall('m1', at: 1700000002000, conversationId: 'c1');
    final record = await repo.byId('m1');
    expect(record!.recallCount, 1);
    expect(record.lastRecalledAt, 1700000002000);
    expect(record.heat, 'hot');
    final recalls = await db.db.query('memory_recalls');
    expect(recalls.length, 1);
  });

  test('召回兜底：命中为空时注入高显著度记忆与历史聊天', () async {
    final now = DateTime.now();
    final earlier = now.subtract(const Duration(days: 2)).millisecondsSinceEpoch;
    await db.db.insert('conversations', {
      'id': 'c1', 'title': '主对话', 'kind': 'main',
      'created_at': earlier, 'updated_at': earlier,
    });
    await db.db.insert('messages', {
      'id': 'msg1', 'client_uuid': 'u1', 'conversation_id': 'c1',
      'role': 'user', 'kind': 'text', 'text': '我今天去了动物园',
      'status': 'sent', 'origin': 'local', 'created_at': earlier,
    });
    await repo.insert(makeRecord(id: 'm1', title: '爱好', content: '用户喜欢摄影', importanceScore: 0.9));

    final builder = RecallContextBuilder(db, repo);
    final lines = await builder.recall(query: '我们以前聊过什么', currentConversationId: 'c1');
    // 泛问句：有 cue → 兜底注入高显著度记忆 + 历史聊天
    expect(lines.any((l) => l.contains('摄影')), isTrue);
    expect(lines.any((l) => l.contains('历史聊天')), isTrue);
  });

  test('resolveDayRange 对齐（上周）', () {
    final range = CurrentTimeContext.resolveDayRange('上周我们做了什么');
    expect(range, isNotNull);
    expect(range!.label, '上周');
  });
}

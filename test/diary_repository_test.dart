/// 日记仓储单测：按天 upsert、版本快照、FTS 检索、软删、校验。
library;

import 'package:dafeiyu_flutter/data/db/app_database.dart';
import 'package:dafeiyu_flutter/data/repositories/diary_repository.dart';
import 'package:dafeiyu_flutter/domain/models/diary.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  late DiaryRepository repo;

  setUp(() async {
    db = await AppDatabase.open(':memory:');
    repo = DiaryRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  DiaryUpsert makeUpsert({
    String date = '2026-01-10',
    String title = '标题',
    String content = '今天一起复盘了项目，聊得很顺。',
    String mood = 'warm',
    String source = 'auto',
    bool isUserEdited = false,
    String changedBy = 'ai',
    String sharedExperience = '一起复盘了项目',
    String observation = '她今天状态不错',
    String feeling = '顺利',
  }) {
    return DiaryUpsert(
      entryDate: date,
      title: title,
      content: content,
      moodCode: mood,
      source: source,
      generatedBy: 'test-model',
      isUserEdited: isUserEdited,
      sharedExperience: sharedExperience,
      observation: observation,
      feeling: feeling,
      relationshipChange: '',
      relationshipChangeConfirmed: false,
      changeReason: '单测',
      changedBy: changedBy,
    );
  }

  test('upsert 新增：返回条目且写版本快照 v1', () async {
    final entry = await repo.upsert(makeUpsert(), atMillis: 1000);
    expect(entry.entryDate, '2026-01-10');
    expect(entry.moodCode, 'warm');
    expect(entry.isUserEdited, isFalse);
    expect(entry.isProtectedFromAutoOverwrite, isFalse);

    final versions = await db.db.query('diary_entry_versions', where: 'diary_id = ?', whereArgs: <Object?>[entry.id]);
    expect(versions, hasLength(1));
    expect(versions.first['version'], 1);
    expect(versions.first['changed_by'], 'ai');
  });

  test('upsert 按 entry_date 覆盖并累加版本', () async {
    final first = await repo.upsert(makeUpsert(content: '第一版'), atMillis: 1000);
    final second = await repo.upsert(makeUpsert(content: '第二版'), atMillis: 2000);
    expect(second.id, first.id);

    final versions = await db.db.query(
      'diary_entry_versions',
      where: 'diary_id = ?',
      whereArgs: <Object?>[first.id],
      orderBy: 'version ASC',
    );
    expect(versions, hasLength(2));
    expect(versions.last['version'], 2);
    expect(versions.last['content'], '第二版');
  });

  test('FTS 检索命中标题/正文/结构化字段', () async {
    final entry = await repo.upsert(makeUpsert(), atMillis: 1000);
    final hits = await repo.search('复盘项目');
    expect(hits, contains(entry.id));
    expect(await repo.search('完全无关的词'), isNot(contains(entry.id)));
  });

  test('软删后不再可查且 FTS 清空', () async {
    final entry = await repo.upsert(makeUpsert(), atMillis: 1000);
    await repo.softDelete(entry.id, atMillis: 3000);

    expect(await repo.entryById(entry.id), isNull);
    expect(await repo.entryByDate('2026-01-10'), isNull);
    expect(await repo.search('复盘项目'), isEmpty);
  });

  test('软删后同一天可重建（唯一索引只约束活行）', () async {
    final old = await repo.upsert(makeUpsert(), atMillis: 1000);
    await repo.softDelete(old.id, atMillis: 3000);
    final rebuilt = await repo.upsert(makeUpsert(content: '重建'), atMillis: 4000);
    expect(rebuilt.id, isNot(old.id));
    expect(await repo.entryByDate('2026-01-10'), isNotNull);
  });

  test('手写日记受保护，自动覆盖会被拒绝（语义层）', () async {
    final manual = await repo.upsert(makeUpsert(source: 'manual', isUserEdited: true, changedBy: 'user'), atMillis: 1000);
    expect(manual.isProtectedFromAutoOverwrite, isTrue);
  });

  test('非法输入被拒绝：空正文 / 非法日期 / 非法编辑者 / 非法情绪码归 null', () async {
    expect(
      () => repo.upsert(makeUpsert(content: '   '), atMillis: 1000),
      throwsA(isA<DiaryError>()),
    );
    expect(
      () => repo.upsert(makeUpsert(date: '2026-13-40'), atMillis: 1000),
      throwsA(isA<DiaryError>()),
    );
    expect(
      () => repo.upsert(makeUpsert(changedBy: 'robot'), atMillis: 1000),
      throwsA(isA<DiaryError>()),
    );

    final entry = await repo.upsert(makeUpsert(mood: '狂喜'), atMillis: 1000);
    expect(entry.moodCode, isNull);
  });

  test('recallLines 输出原版格式，空结构化字段退正文摘要', () async {
    await repo.upsert(makeUpsert(), atMillis: 1000);
    await repo.upsert(makeUpsert(
      date: '2026-01-11',
      title: '过渡的一天',
      content: '没什么特别的事。',
      sharedExperience: '',
      observation: '',
      feeling: '',
    ), atMillis: 2000);

    final lines = await repo.recallLines('2026-01-10', '2026-01-11');
    expect(lines, hasLength(2));
    expect(lines[0], startsWith('【日记·2026-01-10】共同经历：一起复盘了项目'));
    expect(lines[1], '【日记·2026-01-11】没什么特别的事。');
  });
}

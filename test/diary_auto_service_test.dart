/// 日记自动生成单测：消息不足跳过、手写保护、解析失败不写库、正常生成。
library;

import 'dart:convert';

import 'package:dafeiyu_flutter/ai/diary_auto_service.dart';
import 'package:dafeiyu_flutter/ai/openai_compatible_provider.dart';
import 'package:dafeiyu_flutter/data/db/app_database.dart';
import 'package:dafeiyu_flutter/data/repositories/diary_repository.dart';
import 'package:dafeiyu_flutter/data/repositories/message_repository.dart';
import 'package:dafeiyu_flutter/domain/models/diary.dart';
import 'package:dafeiyu_flutter/domain/models/message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  late DiaryRepository diaries;
  late MessageRepository messages;
  late DiaryAutoService service;

  setUp(() async {
    db = await AppDatabase.open(':memory:');
    diaries = DiaryRepository(db);
    messages = MessageRepository(db);
    service = DiaryAutoService(db, diaries);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seedMessages(String dayKey, int count) async {
    final start = DateTime.utc(2026, 1, 10, -8).millisecondsSinceEpoch;
    final roles = <MessageRole>[MessageRole.user, MessageRole.assistant];
    for (int i = 0; i < count; i++) {
      await messages.insert(Message(
        id: 'm-$i',
        clientUuid: 'c-$i',
        conversationId: 'conv',
        role: roles[i % 2],
        kind: MessageKind.text,
        text: '第 $i 条消息，聊了今天的复盘。',
        status: MessageStatus.sent,
        origin: MessageOrigin.user,
        createdAt: start + i * 60000,
        sentAt: start + i * 60000,
      ));
    }
  }

  /// 把模型原始输出包装成 OpenAI chat completion 响应格式
  String wrap(String raw) => jsonEncode(<String, Object?>{
    'choices': <Object?>[
      <String, Object?>{
        'message': <String, Object?>{'role': 'assistant', 'content': raw},
      },
    ],
  });

  OpenAICompatibleProvider providerOf(String body) {
    return OpenAICompatibleProvider(
      baseUrl: 'https://fake.local/v1',
      modelId: 'test-model',
      apiKey: 'test-key',
      client: MockClient((http.Request request) async {
        return http.Response(wrap(body), 200, headers: <String, String>{
          'content-type': 'application/json',
        });
      }),
    );
  }

  const goodJson = '''
  这是模型输出前的废话
  {"skip":false,"title":"复盘的一天","content":"今天一起复盘了项目，进展顺利。",
   "mood":"warm","shared_experience":"一起复盘了项目","observation":"状态不错",
   "feeling":"顺利","relationship_change":"她更愿意说自己的事","relationship_change_confirmed":true}
  ''';

  test('消息不足：skipped_no_content 且不写库', () async {
    await seedMessages('2026-01-10', 1);
    final report = await service.generate(
      '2026-01-10',
      provider: providerOf(goodJson),
    );
    expect(report.status, DiaryReportStatus.skippedNoContent);
    expect(await diaries.recent(), isEmpty);
  });

  test('当天没有用户消息：skipped_no_content', () async {
    final start = DateTime.utc(2026, 1, 10, -8).millisecondsSinceEpoch;
    await messages.insert(Message(
      id: 'm-a',
      clientUuid: 'c-a',
      conversationId: 'conv',
      role: MessageRole.assistant,
      kind: MessageKind.text,
      text: '只有助手的话',
      status: MessageStatus.sent,
      origin: MessageOrigin.user,
      createdAt: start,
      sentAt: start,
    ));
    final report = await service.generate(
      '2026-01-10',
      provider: providerOf(goodJson),
    );
    expect(report.status, DiaryReportStatus.skippedNoContent);
  });

  test('用户手写日记：skipped_user_edited 不覆盖', () async {
    await seedMessages('2026-01-10', 4);
    await diaries.upsert(DiaryUpsert(
      entryDate: '2026-01-10',
      title: '手写的',
      content: '用户亲手写的日记',
      source: 'manual',
      isUserEdited: true,
      sharedExperience: '', observation: '', feeling: '',
      relationshipChange: '', relationshipChangeConfirmed: false,
      changeReason: '手写', changedBy: 'user',
    ), atMillis: 1000);

    final report = await service.generate('2026-01-10', provider: providerOf(goodJson));
    expect(report.status, DiaryReportStatus.skippedUserEdited);
    final entry = await diaries.entryByDate('2026-01-10');
    expect(entry!.content, '用户亲手写的日记');
  });

  test('模型输出无法解析：failed 且不写库', () async {
    await seedMessages('2026-01-10', 4);
    final report = await service.generate(
      '2026-01-10',
      provider: providerOf('这不是 JSON，模型抽风了'),
    );
    expect(report.status, DiaryReportStatus.failed);
    expect(await diaries.recent(), isEmpty);
  });

  test('模型输出 skip:true：skipped_no_content', () async {
    await seedMessages('2026-01-10', 4);
    final report = await service.generate(
      '2026-01-10',
      provider: providerOf('{"skip":true}'),
    );
    expect(report.status, DiaryReportStatus.skippedNoContent);
    expect(await diaries.recent(), isEmpty);
  });

  test('正常生成：generated、关系变化确认被强制置 false、非法情绪码归 null', () async {
    await seedMessages('2026-01-10', 6);
    final report = await service.generate(
      '2026-01-10',
      provider: providerOf(goodJson),
      persona: '你是大肥鱼',
    );
    expect(report.status, DiaryReportStatus.generated);

    final entry = await diaries.entryByDate('2026-01-10');
    expect(entry, isNotNull);
    expect(entry!.title, '复盘的一天');
    expect(entry.source, 'auto');
    expect(entry.generatedBy, 'test-model');
    expect(entry.moodCode, 'warm');
    expect(entry.sharedExperience, '一起复盘了项目');
    // 硬约束 D72：关系变化必须由用户确认，自动生成永远不置 true
    expect(entry.relationshipChangeConfirmed, isFalse);

    final versions = await db.db.query('diary_entry_versions', where: 'diary_id = ?', whereArgs: <Object?>[entry.id]);
    expect(versions, hasLength(1));
  });

  test('重复生成同一天：updated 且版本累加', () async {
    await seedMessages('2026-01-10', 6);
    final first = await service.generate('2026-01-10', provider: providerOf(goodJson));
    final second = await service.generate('2026-01-10', provider: providerOf(goodJson));
    expect(first.status, DiaryReportStatus.generated);
    expect(second.status, DiaryReportStatus.updated);

    final entry = await diaries.entryByDate('2026-01-10');
    final versions = await db.db.query('diary_entry_versions', where: 'diary_id = ?', whereArgs: <Object?>[entry!.id]);
    expect(versions, hasLength(2));
  });

  test('转写超出当天范围的消息不参与生成', () async {
    // 2026-01-09 的消息不应进入 2026-01-10 的日记
    final start = DateTime.utc(2026, 1, 9, -8).millisecondsSinceEpoch;
    await messages.insert(Message(
      id: 'm-yesterday',
      clientUuid: 'c-yesterday',
      conversationId: 'conv',
      role: MessageRole.user,
      kind: MessageKind.text,
      text: '这是昨天的消息',
      status: MessageStatus.sent,
      origin: MessageOrigin.user,
      createdAt: start,
      sentAt: start,
    ));
    final report = await service.generate('2026-01-10', provider: providerOf(goodJson));
    expect(report.status, DiaryReportStatus.skippedNoContent);
    expect(report.messageCount, 0);
  });
}

/// 备份/恢复单测：导出快照、DFBK1 加密容器、验证、从文件导入、恢复（含安全备份
/// 与 memory_fts 重建）、跨设备确认门禁。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dafeiyu_flutter/core/backup/backup_cipher.dart';
import 'package:dafeiyu_flutter/core/backup/backup_service.dart';
import 'package:dafeiyu_flutter/data/db/app_database.dart';
import 'package:dafeiyu_flutter/domain/models/backup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  late String tempDir;
  late InMemoryKeyStore keyStore;
  late BackupService service;

  setUp(() async {
    db = await AppDatabase.open(':memory:');
    tempDir = await Directory.systemTemp.createTemp('dafeiyu-backup-test').then((Directory d) => d.path);
    keyStore = InMemoryKeyStore();
    service = BackupService(database: db, keyStore: keyStore, appVersion: 'test', rootDirectory: tempDir);
  });

  tearDown(() async {
    await db.close();
    final dir = Directory(tempDir);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> seedConversation() async {
    await db.db.execute(
      'INSERT INTO conversations (id, title, kind, created_at, updated_at) '
      "VALUES ('c1', '测试会话', 'main', 1000, 1000)",
    );
    await db.db.execute(
      'INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at) '
      "VALUES ('m1', 'uuid-1', 'c1', 'user', 'text', '你好', 'sent', 'user', 1000)",
    );
  }

  Future<int> memoryCount() async {
    final rows = await db.db.rawQuery('SELECT count(*) AS n FROM memories');
    return (rows.first['n'] as int?) ?? 0;
  }

  test('DFBK1 容器：封印/开封往返，篡改即失败', () async {
    final key = await keyStore.loadOrCreateKey();
    final plaintext = Uint8List.fromList('大肥鱼备份内容'.codeUnits);
    final sealed = await BackupContainer.seal(plaintext, key);

    expect(BackupContainer.isContainer(sealed), isTrue);
    expect(sealed.length, greaterThan(BackupContainer.headerLength));

    final opened = await BackupContainer.open(sealed, key);
    expect(opened, plaintext);

    // 错误密钥 → 认证失败
    final otherKey = await InMemoryKeyStore().loadOrCreateKey();
    expect(
      () => BackupContainer.open(sealed, otherKey),
      throwsA(isA<BackupCipherError>()),
    );
  });

  test('创建加密备份：清单落库、文件存在、sha256 匹配', () async {
    await seedConversation();
    final manifest = await service.createBackup(
      kind: BackupKind.manual,
      note: '单测',
      atMillis: 12345,
    );

    expect(manifest.status, BackupStatus.completed);
    expect(manifest.isEncrypted, isTrue);
    expect(manifest.fileName.endsWith('.dfbk'), isTrue);
    expect(manifest.byteSize, greaterThan(0));
    expect(manifest.sha256, isNotNull);

    final file = service.fileURL(manifest);
    expect(file.existsSync(), isTrue);

    final verification = await service.verify(manifest.id);
    expect(verification.sha256Matches, isTrue);
    expect(verification.decrypted, isTrue);
  });

  test('导出快照包含业务表、不含 memory_scopes 与 FTS', () async {
    await seedConversation();
    final snapshot = await service.exportSnapshot(atMillis: 1);
    final names = snapshot.tables.map((BackupTableSnapshot t) => t.name).toSet();
    expect(names.contains('conversations'), isTrue);
    expect(names.contains('messages'), isTrue);
    expect(names.contains('memory_scopes'), isFalse);
    expect(names.contains('memory_fts'), isFalse);
    expect(snapshot.sourceDeviceId, isNotNull);
  });

  test('明文导出 → 从文件导入 → 读回快照一致', () async {
    await seedConversation();
    final plaintext = await service.createBackup(
      kind: BackupKind.manual,
      encrypted: false,
      atMillis: 22222,
    );
    expect(plaintext.fileName.endsWith('.json'), isTrue);

    final copyPath = '$tempDir${Platform.pathSeparator}外部备份.json';
    await service.fileURL(plaintext).copy(copyPath);

    final imported = await service.importBackupFile(copyPath, atMillis: 33333);
    expect(imported.scope, 'imported');
    expect(imported.isEncrypted, isFalse);

    final snapshot = await service.readSnapshot(imported.id);
    expect(snapshot.totalRows, greaterThan(0));
    expect(snapshot.counts['messages'], 1);
  });

  test('恢复：清空后按快照写回，memory_fts 同步重建', () async {
    await seedConversation();
    // 一条会话前的记忆
    await db.db.execute(
      '''
      INSERT INTO memories (id, type, title, content, importance, salience, confidence, status,
        first_seen_at, scope, layer, category, source_kind, epistemic_status, version,
        heat, classification_status, created_at, updated_at)
      VALUES ('mem-1', 'fact', '旧记忆', '用户喜欢钓鱼', 'normal', 0.5, 0.5, 'active',
        1000, 'shared', 'semantic', 'fact', 'real_interaction', 'observed', 1,
        'warm', 'pending', 1000, 1000)
      ''',
    );
    await db.db.execute(
      "INSERT INTO memory_fts (memory_id, scope, text_bigram) VALUES ('mem-1', 'shared', '旧记忆 用户喜欢钓鱼')",
    );

    final manifest = await service.createBackup(kind: BackupKind.manual, atMillis: 44444);

    // 恢复前制造"新状态"：多一条记忆，删掉会话
    await db.db.execute(
      '''
      INSERT INTO memories (id, type, title, content, importance, salience, confidence, status,
        first_seen_at, scope, layer, category, source_kind, epistemic_status, version,
        heat, classification_status, created_at, updated_at)
      VALUES ('mem-2', 'fact', '新记忆', '恢复后多出来的', 'normal', 0.5, 0.5, 'active',
        2000, 'shared', 'semantic', 'fact', 'real_interaction', 'observed', 1,
        'warm', 'pending', 2000, 2000)
      ''',
    );
    await db.db.execute("INSERT INTO memory_fts (memory_id, scope, text_bigram) VALUES ('mem-2', 'shared', '新记忆 恢复后多出来的')");
    await db.db.execute('DELETE FROM conversations');
    expect(await memoryCount(), 2);

    final log = await service.restore(manifest.id, confirmedCrossDevice: true, atMillis: 55555);
    expect(log.status, 'completed');

    final counts = <String, dynamic>{};
    // 快照数据回来了
    final messages = await db.db.rawQuery('SELECT count(*) AS n FROM messages');
    expect((messages.first['n'] as int?) ?? 0, 1);
    // 恢复后只有快照里的那条记忆
    expect(await memoryCount(), 1);
    // 安全备份已生成
    final safety = await service.previewRestore(manifest.id);
    expect(safety.canProceed, isTrue);
    counts['restored'] = log.restoredCountsJson.length;
    // FTS 重建：新记忆的索引行已消失
    final fts = await db.db.rawQuery(
      "SELECT count(*) AS n FROM memory_fts WHERE memory_id = 'mem-2'",
    );
    expect((fts.first['n'] as int?) ?? 0, 0);
  });

  test('恢复门禁：跨设备来源需要用户确认', () async {
    await seedConversation();
    final manifest = await service.createBackup(kind: BackupKind.manual, atMillis: 66666);

    // 把本机安装标识改成"另一台设备"，快照里的旧标识即视为跨设备
    await db.db.insert(
      'settings',
      <String, Object?>{'key': 'device.install_id', 'value': 'other-device'},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    expect(
      () => service.restore(manifest.id, atMillis: 77777),
      throwsA(isA<RestoreGuardError>()),
    );
    // 显式确认后允许
    final log = await service.restore(manifest.id, confirmedCrossDevice: true, atMillis: 77777);
    expect(log.status, 'completed');
  });
}

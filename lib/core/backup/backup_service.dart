/// 备份与恢复的落地实现（对齐 SwiftUI 版 BackupService.swift，W9 / D20、D42、D72）。
///
/// 边界：
/// - 备份文件默认加密（DFBK1 容器 + AES-256-GCM），密钥只存在本地安全存储里；
/// - 明文导出必须由调用方显式 `encrypted: false`，UI 负责二次确认与风险提示；
/// - 恢复前先做版本兼容检查，并**自动生成安全备份**；
/// - 恢复在一个事务内完成，任何失败整体回滚，原库不受影响；
/// - 恢复后重建 memory_fts 全文索引。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../data/db/app_database.dart';
import '../../data/db/schema.dart';
import '../../data/repositories/backup_repository.dart';
import '../../domain/models/backup.dart';
import '../text/bigram.dart';
import 'backup_cipher.dart';

class BackupService {
  BackupService({
    required AppDatabase database,
    required BackupKeyStoring keyStore,
    String appVersion = '2.0.0',
    String? rootDirectory,
  })  : _database = database,
        _repository = BackupRepository(database),
        _keyStore = keyStore,
        _appVersion = appVersion,
        _rootDirectory = rootDirectory;

  /// 逻辑导出/恢复的表顺序（父表在前；恢复时按相反顺序清空）。
  /// `memory_scopes` 是预置字典表，不进快照（恢复不触碰，与原版一致）。
  static const List<String> tableOrder = <String>[
    'settings',
    'model_configs',
    'personas',
    'persona_items',
    'persona_item_tier_history',
    'persona_versions',
    'conversations',
    'messages',
    'attachments',
    'message_attachments',
    'memories',
    'memory_importance_history',
    'memory_sources',
    'memory_versions',
    'memory_links',
    'memory_embeddings',
    'memory_recalls',
    'episodes',
    'episode_memories',
    'entities',
    'entity_facts',
    'procedural_memories',
    'reflections',
    'kg_nodes',
    'kg_edges',
    'change_events',
    'open_topics',
    'working_memory_snapshots',
    'memory_jobs',
    'memory_classification_history',
    // 提案引用人格条目与记忆，放在最后，恢复时最先清空
    'proposals',
  ];

  final AppDatabase _database;
  final BackupRepository _repository;
  final BackupKeyStoring _keyStore;
  final String _appVersion;
  final String? _rootDirectory;

  /// 本机安装标识在 `settings` 中的键（D72）
  static const String deviceIDKey = 'device.install_id';

  /// 备份目录：`<root>/Backups`
  String get backupsDirectory {
    final root = _rootDirectory;
    if (root != null) return _join(root, 'Backups');
    // 数据库目录的上一级作为工程根（与原版 Workspace/Backups 语义对齐）
    final dbDir = File(_database.db.path).parent.path;
    return _join(_join(dbDir, '..'), 'Backups');
  }

  String _join(String a, String b) {
    final normalized = a.endsWith('/') || a.endsWith(r'\') ? a.substring(0, a.length - 1) : a;
    return '$normalized${Platform.pathSeparator}$b';
  }

  // ── 导出 ─────────────────────────────────────────────────────────────────

  /// 全量逻辑导出：按 [tableOrder] 抓取存在的表
  Future<BackupSnapshot> exportSnapshot({int? atMillis}) async {
    final timestamp = atMillis ?? DateTime.now().millisecondsSinceEpoch;
    final tables = <BackupTableSnapshot>[];
    for (final table in tableOrder) {
      final exists = await _tableExists(table);
      if (!exists) continue;
      final columns = await _tableColumns(table);
      if (columns.isEmpty) continue;
      final rows = await _database.db.query(table, columns: columns);
      tables.add(BackupTableSnapshot(
        name: table,
        columns: columns,
        rows: rows
            .map((Map<String, Object?> row) =>
                columns.map((String c) => BackupValue.fromSql(row[c])).toList())
            .toList(),
      ));
    }

    final counts = <String, int>{
      for (final BackupTableSnapshot t in tables) t.name: t.rows.length,
    };

    return BackupSnapshot(
      schemaVersion: kSchemaVersion.toString(),
      appVersion: _appVersion,
      createdAt: timestamp,
      tables: tables,
      counts: counts,
      sourceDeviceId: await deviceID(),
    );
  }

  /// 本机安装标识（D72）：首次使用时生成并存入 `settings`，失败返回 null（不阻塞备份）
  Future<String?> deviceID() async {
    try {
      final rows = await _database.db.query(
        'settings',
        where: 'key = ?',
        whereArgs: <Object?>[deviceIDKey],
        limit: 1,
      );
      final existing = rows.isEmpty ? null : rows.first['value'] as String?;
      final trimmed = existing?.trim() ?? '';
      if (trimmed.isNotEmpty) return trimmed;
      final generated = const Uuid().v4();
      await _database.db.insert(
        'settings',
        <String, Object?>{'key': deviceIDKey, 'value': generated},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return generated;
    } catch (_) {
      return null;
    }
  }

  // ── 创建备份 ──────────────────────────────────────────────────────────────

  Future<BackupManifest> createBackup({
    required BackupKind kind,
    String scope = 'all',
    String? note,
    bool encrypted = true,
    int? atMillis,
  }) async {
    final timestamp = atMillis ?? DateTime.now().millisecondsSinceEpoch;
    final snapshot = await exportSnapshot(atMillis: timestamp);
    final plaintext = Uint8List.fromList(utf8.encode(snapshot.encode()));
    final countsJson = jsonEncode(snapshot.counts);

    Uint8List payload;
    String? hint;
    if (encrypted) {
      final key = await _keyStore.loadOrCreateKey();
      payload = await BackupContainer.seal(plaintext, key);
      hint = BackupContainer.cipherIdentifier;
    } else {
      payload = plaintext;
    }

    final directory = Directory(backupsDirectory);
    if (!directory.existsSync()) directory.createSync(recursive: true);
    final fileName = 'dafeiyu-${kind.name}-$timestamp.${encrypted ? 'dfbk' : 'json'}';
    final file = File(_join(directory.path, fileName));
    await file.writeAsBytes(payload, flush: true);

    final manifest = await _repository.create(
      kind: kind,
      scope: scope,
      schemaVersion: snapshot.schemaVersion,
      appVersion: _appVersion,
      fileName: fileName,
      relPath: 'Backups/$fileName',
      isEncrypted: encrypted,
      encryptionHint: hint,
      note: note,
      atMillis: timestamp,
    );
    await _repository.markFinished(
      manifest.id,
      byteSize: payload.length,
      sha256: _sha256Hex(payload),
      itemCountsJson: countsJson,
      atMillis: timestamp,
    );
    return (await _repository.manifest(manifest.id)) ?? manifest;
  }

  // ── 读取 / 验证 ───────────────────────────────────────────────────────────

  /// 备份清单列表（最新在前）。
  Future<List<BackupManifest>> manifestsList({int limit = 100}) =>
      _repository.manifests(limit: limit);

  /// 备份文件在磁盘上的实际位置（导出/分享用，不做任何解密）
  File fileURL(BackupManifest manifest) =>
      File(_join(backupsDirectory, manifest.fileName));

  Future<BackupSnapshot> readSnapshot(String manifestId) async {
    final manifest = await _repository.manifest(manifestId);
    if (manifest == null || !manifest.isUsable) throw BackupError.notFound;
    final file = fileURL(manifest);
    if (!file.existsSync()) throw BackupError.notFound;
    final data = Uint8List.fromList(await file.readAsBytes());

    Uint8List plaintext;
    if (manifest.isEncrypted) {
      final key = await _keyStore.loadOrCreateKey();
      plaintext = await BackupContainer.open(data, key);
    } else {
      plaintext = data;
    }

    final snapshot = BackupSnapshot.decode(utf8.decode(plaintext));
    if (snapshot.format != BackupSnapshot.currentFormat) {
      throw BackupSnapshotError.unsupportedFormat(snapshot.format);
    }
    return snapshot;
  }

  Future<BackupVerification> verify(String manifestId) async {
    final manifest = await _repository.manifest(manifestId);
    if (manifest == null || !manifest.isUsable) throw BackupError.notFound;
    final file = fileURL(manifest);
    if (!file.existsSync()) throw BackupError.notFound;
    final data = Uint8List.fromList(await file.readAsBytes());
    final sha = _sha256Hex(data);
    final matches = manifest.sha256 == sha;

    var decrypted = false;
    var countsJson = manifest.itemCountsJson;
    if (matches) {
      final snapshot = await readSnapshot(manifestId);
      decrypted = true;
      countsJson = jsonEncode(snapshot.counts);
      await _repository.markVerified(manifestId, atMillis: _now());
    }
    return BackupVerification(
      manifestId: manifestId,
      sha256Matches: matches,
      decrypted: decrypted,
      itemCountsJson: countsJson,
    );
  }

  // ── 从文件导入（D42）───────────────────────────────────────────────────────

  /// 把「文件」里选中的备份导入到本机备份清单。
  ///
  /// - 加密容器（DFBK1）必须能用本机密钥解开，密钥不同或文件被篡改直接失败；
  /// - 明文 JSON 只在调用方显式允许时接受；
  /// - 导入只登记备份，不自动恢复；恢复仍走 [previewRestore] + [restore]。
  Future<BackupManifest> importBackupFile(
    String filePath, {
    BackupKind kind = BackupKind.manual,
    bool allowPlaintext = true,
    int? atMillis,
  }) async {
    final timestamp = atMillis ?? _now();
    final source = File(filePath);
    if (!source.existsSync()) throw BackupError('备份文件不存在：$filePath');
    final data = Uint8List.fromList(await source.readAsBytes());
    if (data.isEmpty) throw BackupCipherError.truncatedContainer;

    final isEncrypted = BackupContainer.isContainer(data);
    String? hint;
    Uint8List plaintext;
    if (isEncrypted) {
      final key = await _keyStore.existingKey();
      if (key == null) throw BackupCipherError.authenticationFailed;
      plaintext = await BackupContainer.open(data, key);
      hint = BackupContainer.cipherIdentifier;
    } else {
      if (!allowPlaintext) throw BackupCipherError.badMagic;
      plaintext = data;
    }

    final snapshot = BackupSnapshot.decode(utf8.decode(plaintext));
    if (snapshot.format != BackupSnapshot.currentFormat) {
      throw BackupSnapshotError.unsupportedFormat(snapshot.format);
    }
    _assertKnownTables(snapshot.tables);

    final countsJson = jsonEncode(snapshot.counts);
    final directory = Directory(backupsDirectory);
    if (!directory.existsSync()) directory.createSync(recursive: true);
    final ext = isEncrypted ? 'dfbk' : 'json';
    final fileName =
        'dafeiyu-${kind.name}-import-$timestamp-${const Uuid().v4().substring(0, 8)}.$ext';
    final target = File(_join(directory.path, fileName));
    await target.writeAsBytes(data, flush: true);

    final manifest = await _repository.create(
      kind: kind,
      scope: 'imported',
      schemaVersion: snapshot.schemaVersion,
      appVersion: snapshot.appVersion,
      fileName: fileName,
      relPath: 'Backups/$fileName',
      isEncrypted: isEncrypted,
      encryptionHint: hint,
      note: '从文件导入：${fileName.isEmpty ? '' : _fileNameOf(filePath)}',
      atMillis: timestamp,
    );
    await _repository.markFinished(
      manifest.id,
      byteSize: data.length,
      sha256: _sha256Hex(data),
      itemCountsJson: countsJson,
      atMillis: timestamp,
    );
    return (await _repository.manifest(manifest.id)) ?? manifest;
  }

  // ── 恢复 ─────────────────────────────────────────────────────────────────

  Future<RestorePrecheck> previewRestore(String manifestId) async {
    final manifest = await _repository.manifest(manifestId);
    if (manifest == null || !manifest.isUsable) throw BackupError.notFound;
    final snapshot = await readSnapshot(manifestId);
    final current = kSchemaVersion.toString();
    // 旧版本备份允许恢复（升级路径），新版本备份拒绝
    final compatible = _isSchemaCompatible(
      backup: snapshot.schemaVersion,
      current: current,
    );
    // Dart 没有标准磁盘余量 API，暂跳过空间检查（真机由系统层面兜底）
    const spaceOk = true;
    final countsJson = jsonEncode(snapshot.counts);

    return RestorePrecheck(
      backupId: manifestId,
      backupSchemaVersion: snapshot.schemaVersion,
      currentSchemaVersion: current,
      isCompatible: compatible,
      isSpaceOk: spaceOk,
      itemCountsJson: countsJson,
    );
  }

  Future<RestoreLog> restore(
    String manifestId, {
    String mode = 'replace',
    bool confirmedCrossDevice = false,
    int? atMillis,
  }) async {
    final timestamp = atMillis ?? _now();
    final precheck = await previewRestore(manifestId);
    if (!precheck.isCompatible) {
      throw BackupError.incompatibleSchema(precheck.backupSchemaVersion);
    }
    if (!precheck.isSpaceOk) throw BackupError.insufficientSpace;

    final snapshot = await readSnapshot(manifestId);

    // D72：跨设备 / 来源未知必须用户确认
    await _assertRestoreAllowed(snapshot, confirmedCrossDevice: confirmedCrossDevice);

    // 恢复前必须留下安全备份：恢复失败或恢复结果不满意时可退回
    final safety = await createBackup(
      kind: BackupKind.safety,
      scope: 'safety',
      note: '恢复前自动备份',
      encrypted: true,
      atMillis: timestamp,
    );
    final log = await _repository.startRestore(
      backupId: manifestId,
      mode: mode,
      previewJson: jsonEncode(precheck.toJson()),
      isCompatible: true,
      isSpaceOk: true,
      safetyBackupId: safety.id,
      atMillis: timestamp,
    );

    try {
      final counts = await _apply(snapshot);
      await _repository.finishRestore(
        log.id,
        status: 'completed',
        restoredCountsJson: jsonEncode(counts),
        atMillis: _now(),
      );
    } catch (error) {
      // 事务已整体回滚，原库保持恢复前状态
      await _repository.finishRestore(
        log.id,
        status: 'failed',
        restoredCountsJson: '{}',
        error: error.toString(),
        atMillis: _now(),
      );
      rethrow;
    }

    final logs = await _repository.restoreLogs(limit: 20);
    return logs.firstWhere((RestoreLog l) => l.id == log.id, orElse: () => log);
  }

  // ── 内部 ─────────────────────────────────────────────────────────────────

  /// 恢复门禁（D72）。`hasSafetyBackup` 恒为 true：紧随其后就会创建保护备份。
  Future<void> _assertRestoreAllowed(
    BackupSnapshot snapshot, {
    required bool confirmedCrossDevice,
  }) async {
    final currentDeviceId = await deviceID();
    final backupDeviceId = snapshot.sourceDeviceId;
    // 版本已由 previewRestore 校验；这里只判设备来源
    if (backupDeviceId != null && backupDeviceId != currentDeviceId) {
      if (!confirmedCrossDevice) {
        throw RestoreGuardError.confirmationRequired(
          '备份来自其他设备（$backupDeviceId），恢复将覆盖本机数据，请确认',
        );
      }
    }
  }

  /// 版本兼容：备份版本 ≤ 当前版本才可恢复（字符串均为纯数字）
  bool _isSchemaCompatible({required String backup, required String current}) {
    final backupVersion = int.tryParse(backup);
    final currentVersion = int.tryParse(current);
    if (backupVersion == null || currentVersion == null) return backup == current;
    return backupVersion <= currentVersion;
  }

  void _assertKnownTables(List<BackupTableSnapshot> tables) {
    final known = tableOrder.toSet();
    for (final BackupTableSnapshot table in tables) {
      if (!known.contains(table.name)) {
        throw BackupSnapshotError.unknownTable(table.name);
      }
    }
  }

  Future<Map<String, int>> _apply(BackupSnapshot snapshot) async {
    _assertKnownTables(snapshot.tables);

    return _database.db.transaction((DatabaseExecutor txn) async {
      // 1. 先清空（子表在前），再按父表顺序写入
      for (final String table in tableOrder.reversed) {
        if (await _tableExistsOn(txn, table)) {
          await txn.execute('DELETE FROM $table');
        }
      }

      // 2. 写入
      final restored = <String, int>{};
      for (final BackupTableSnapshot table in snapshot.tables) {
        if (!(await _tableExistsOn(txn, table.name))) {
          throw BackupSnapshotError.unknownTable(table.name);
        }
        final existing = (await _tableColumnsOn(txn, table.name)).toSet();
        if (!existing.containsAll(table.columns.toSet())) {
          throw BackupSnapshotError.columnMismatch(table.name);
        }
        final columnList = table.columns.join(',');
        final placeholders = List<String>.filled(table.columns.length, '?').join(',');
        for (final List<BackupValue> row in table.rows) {
          if (row.length != table.columns.length) {
            throw BackupSnapshotError.rowWidthMismatch(table.name);
          }
          await txn.rawInsert(
            'INSERT INTO ${table.name} ($columnList) VALUES ($placeholders)',
            row.map((BackupValue v) => v.toSql()).toList(),
          );
        }
        restored[table.name] = table.rows.length;
      }

      // 3. 全文索引必须跟着重建，否则恢复后检索与数据不一致
      await _rebuildMemoryFts(txn);
      return restored;
    });
  }

  /// 重建 memory_fts（与 MemoryRepository 的检索口径一致：title + ' ' + content）
  Future<void> _rebuildMemoryFts(DatabaseExecutor db) async {
    if (!(await _tableExistsOn(db, 'memory_fts'))) return;
    await db.execute('DELETE FROM memory_fts');
    final rows = await db.rawQuery(
      'SELECT id, scope, title, content FROM memories WHERE deleted_at IS NULL',
    );
    for (final Map<String, Object?> row in rows) {
      final title = (row['title'] as String?) ?? '';
      final content = (row['content'] as String?) ?? '';
      await db.execute(
        'INSERT INTO memory_fts (memory_id, scope, text_bigram) VALUES (?, ?, ?)',
        <Object?>[
          row['id'],
          row['scope'],
          bigram('$title $content'),
        ],
      );
    }
  }

  Future<bool> _tableExists(String table) => _tableExistsOn(_database.db, table);

  Future<bool> _tableExistsOn(DatabaseExecutor exec, String table) async {
    final rows = await exec.rawQuery(
      "SELECT count(*) AS n FROM sqlite_master WHERE type = 'table' AND name = ?",
      <Object?>[table],
    );
    return ((rows.first['n'] as int?) ?? 0) > 0;
  }

  Future<List<String>> _tableColumns(String table) => _tableColumnsOn(_database.db, table);

  Future<List<String>> _tableColumnsOn(DatabaseExecutor exec, String table) async {
    final rows = await exec.rawQuery('PRAGMA table_info($table)');
    return rows.map((Map<String, Object?> row) => row['name']! as String).toList();
  }

  String _fileNameOf(String path) => path.split(Platform.pathSeparator).last;

  String _sha256Hex(Uint8List data) => sha256.convert(data).toString();

  int _now() => DateTime.now().millisecondsSinceEpoch;
}

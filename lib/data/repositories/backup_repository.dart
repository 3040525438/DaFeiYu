/// 备份清单与恢复日志仓储（对齐 SwiftUI 版 GRDBBackupRepository）。
library;

import 'package:uuid/uuid.dart';

import '../../domain/models/backup.dart';
import '../db/app_database.dart';

class BackupRepository {
  BackupRepository(this._db);

  final AppDatabase _db;

  /// 新建"待写入"清单；文件落盘后调用 [markFinished]。
  Future<BackupManifest> create({
    required BackupKind kind,
    required String scope,
    required String schemaVersion,
    required String appVersion,
    required String fileName,
    required String relPath,
    required bool isEncrypted,
    String? encryptionHint,
    String? note,
    required int atMillis,
  }) async {
    final manifest = BackupManifest(
      id: const Uuid().v4(),
      kind: kind,
      scope: scope,
      status: BackupStatus.pending,
      schemaVersion: schemaVersion,
      appVersion: appVersion,
      fileName: fileName,
      relPath: relPath,
      byteSize: 0,
      isEncrypted: isEncrypted,
      encryptionHint: encryptionHint,
      itemCountsJson: '{}',
      note: note,
      createdAt: atMillis,
    );
    await _db.db.insert('backup_manifests', manifest.toRow());
    return manifest;
  }

  Future<void> markFinished(
    String id, {
    required int byteSize,
    String? sha256,
    required String itemCountsJson,
    required int atMillis,
  }) async {
    await _db.db.update(
      'backup_manifests',
      <String, Object?>{
        'status': BackupStatus.completed.name,
        'byte_size': byteSize,
        'sha256': sha256,
        'item_counts_json': itemCountsJson,
        'finished_at': atMillis,
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> markFailed(String id, {required int atMillis}) async {
    await _db.db.update(
      'backup_manifests',
      <String, Object?>{
        'status': BackupStatus.failed.name,
        'finished_at': atMillis,
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> markVerified(String id, {required int atMillis}) async {
    await _db.db.update(
      'backup_manifests',
      <String, Object?>{
        'status': BackupStatus.verified.name,
        'verified_at': atMillis,
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<BackupManifest?> manifest(String id) async {
    final rows = await _db.db.query(
      'backup_manifests',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return BackupManifest.fromRow(rows.first);
  }

  Future<List<BackupManifest>> manifests({BackupKind? kind, int limit = 100}) async {
    final rows = await _db.db.query(
      'backup_manifests',
      where: kind == null ? null : 'kind = ?',
      whereArgs: kind == null ? null : <Object?>[kind.name],
      orderBy: 'created_at DESC',
      limit: limit.clamp(1, 500),
    );
    return rows.map(BackupManifest.fromRow).toList();
  }

  Future<BackupManifest?> latest({BackupKind? kind}) async {
    final all = await manifests(kind: kind, limit: 1);
    return all.isEmpty ? null : all.first;
  }

  Future<void> delete(String id) async {
    await _db.db.delete('backup_manifests', where: 'id = ?', whereArgs: <Object?>[id]);
  }

  /// 保留策略：保留最近 [keepCount] 份，其余可清理；
  /// `verified` 与 `safety` 永不自动清理（D43）。
  Future<List<BackupManifest>> prunable(int keepCount, {required int atMillis}) async {
    final rows = await _db.db.rawQuery('''
      SELECT * FROM backup_manifests
       WHERE status NOT IN (?, ?)
         AND scope <> ?
         AND id NOT IN (
           SELECT id FROM backup_manifests ORDER BY created_at DESC LIMIT ?
         )
       ORDER BY created_at DESC
    ''', <Object?>[
      BackupStatus.verified.name,
      BackupStatus.failed.name,
      'safety',
      keepCount.clamp(0, 500),
    ]);
    return rows.map(BackupManifest.fromRow).toList();
  }

  /// 开始一次恢复：写入 pending 日志，随后 [finishRestore]。
  Future<RestoreLog> startRestore({
    required String? backupId,
    required String mode,
    required String previewJson,
    required bool isCompatible,
    required bool isSpaceOk,
    required String? safetyBackupId,
    required int atMillis,
  }) async {
    final log = RestoreLog(
      id: const Uuid().v4(),
      backupId: backupId,
      mode: mode,
      status: 'running',
      previewJson: previewJson,
      isCompatible: isCompatible,
      isSpaceOk: isSpaceOk,
      safetyBackupId: safetyBackupId,
      restoredCountsJson: '{}',
      startedAt: atMillis,
    );
    await _db.db.insert('restore_logs', log.toRow());
    return log;
  }

  Future<void> finishRestore(
    String id, {
    required String status,
    required String restoredCountsJson,
    String? error,
    required int atMillis,
  }) async {
    await _db.db.update(
      'restore_logs',
      <String, Object?>{
        'status': status,
        'restored_counts_json': restoredCountsJson,
        'error': error,
        'finished_at': atMillis,
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<List<RestoreLog>> restoreLogs({int limit = 20}) async {
    final rows = await _db.db.query(
      'restore_logs',
      orderBy: 'started_at DESC',
      limit: limit.clamp(1, 200),
    );
    return rows.map(RestoreLog.fromRow).toList();
  }

  /// 备份占用总字节（存储分类展示，D66）
  Future<int> totalBytes() async {
    final rows = await _db.db.rawQuery(
      'SELECT COALESCE(SUM(byte_size), 0) AS total FROM backup_manifests',
    );
    return (rows.first['total'] as int?) ?? 0;
  }
}

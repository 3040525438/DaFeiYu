/// 备份与恢复领域模型（对齐 SwiftUI 版 DFCore `Backup.swift` / `BackupCrypto.swift`）。
///
/// 说明：
/// - 备份默认加密（DFBK1 容器 + AES-256-GCM），明文导出必须由 UI 二次确认后显式关闭；
/// - 快照为「逻辑导出」：只含业务表，不含 FTS 虚表与视图（恢复后重建索引）；
/// - `BackupValue` 的 JSON 编码为 Flutter 版自定义格式（空值→null、BLOB→标记对象），
///   与 iOS 版 Swift 合成 Codable 的容器格式不互读；列形态本身保持一致。
library;

import 'dart:convert';

/// 备份类型
enum BackupKind {
  manual,
  automatic,
  incremental,
  external,
  safety;

  static BackupKind fromWire(String? value) {
    return BackupKind.values.firstWhere(
      (BackupKind kind) => kind.name == value,
      orElse: () => BackupKind.manual,
    );
  }
}

/// 备份状态
enum BackupStatus {
  pending,
  running,
  completed,
  failed,
  verified;

  static BackupStatus fromWire(String? value) {
    return BackupStatus.values.firstWhere(
      (BackupStatus status) => status.name == value,
      orElse: () => BackupStatus.pending,
    );
  }
}

/// 备份清单（`backup_manifests` 一行）
class BackupManifest {
  BackupManifest({
    required this.id,
    required this.kind,
    required this.scope,
    required this.status,
    required this.schemaVersion,
    required this.appVersion,
    required this.fileName,
    required this.relPath,
    required this.byteSize,
    this.sha256,
    required this.isEncrypted,
    this.encryptionHint,
    required this.itemCountsJson,
    this.note,
    required this.createdAt,
    this.finishedAt,
    this.verifiedAt,
    this.retentionUntil,
  });

  final String id;
  final BackupKind kind;
  final String scope;
  final BackupStatus status;
  final String schemaVersion;
  final String appVersion;
  final String fileName;
  final String relPath;
  final int byteSize;
  final String? sha256;
  final bool isEncrypted;
  final String? encryptionHint;
  final String itemCountsJson;
  final String? note;
  final int createdAt;
  final int? finishedAt;
  final int? verifiedAt;
  final int? retentionUntil;

  /// 只有完成或已验证的备份才可读/可恢复
  bool get isUsable => status == BackupStatus.completed || status == BackupStatus.verified;

  Map<String, Object?> toRow() => <String, Object?>{
    'id': id,
    'kind': kind.name,
    'scope': scope,
    'status': status.name,
    'schema_version': schemaVersion,
    'app_version': appVersion,
    'file_name': fileName,
    'rel_path': relPath,
    'byte_size': byteSize,
    'sha256': sha256,
    'is_encrypted': isEncrypted ? 1 : 0,
    'encryption_hint': encryptionHint,
    'item_counts_json': itemCountsJson,
    'note': note,
    'created_at': createdAt,
    'finished_at': finishedAt,
    'verified_at': verifiedAt,
    'retention_until': retentionUntil,
  };

  static BackupManifest fromRow(Map<String, Object?> row) => BackupManifest(
    id: row['id']! as String,
    kind: BackupKind.fromWire(row['kind'] as String?),
    scope: row['scope']! as String,
    status: BackupStatus.fromWire(row['status'] as String?),
    schemaVersion: row['schema_version']! as String,
    appVersion: (row['app_version'] as String?) ?? '',
    fileName: row['file_name']! as String,
    relPath: row['rel_path']! as String,
    byteSize: (row['byte_size'] as int?) ?? 0,
    sha256: row['sha256'] as String?,
    isEncrypted: ((row['is_encrypted'] as int?) ?? 1) != 0,
    encryptionHint: row['encryption_hint'] as String?,
    itemCountsJson: (row['item_counts_json'] as String?) ?? '{}',
    note: row['note'] as String?,
    createdAt: row['created_at']! as int,
    finishedAt: row['finished_at'] as int?,
    verifiedAt: row['verified_at'] as int?,
    retentionUntil: row['retention_until'] as int?,
  );
}

/// 恢复日志（`restore_logs` 一行）
class RestoreLog {
  RestoreLog({
    required this.id,
    required this.backupId,
    required this.mode,
    required this.status,
    required this.previewJson,
    required this.isCompatible,
    required this.isSpaceOk,
    required this.safetyBackupId,
    required this.restoredCountsJson,
    required this.startedAt,
    this.finishedAt,
    this.error,
  });

  final String id;
  final String? backupId;
  final String mode;
  final String status;
  final String previewJson;
  final bool isCompatible;
  final bool isSpaceOk;
  final String? safetyBackupId;
  final String restoredCountsJson;
  final int startedAt;
  final int? finishedAt;
  final String? error;

  Map<String, Object?> toRow() => <String, Object?>{
    'id': id,
    'backup_id': backupId,
    'mode': mode,
    'status': status,
    'preview_json': previewJson,
    'is_compatible': isCompatible ? 1 : 0,
    'is_space_ok': isSpaceOk ? 1 : 0,
    'safety_backup_id': safetyBackupId,
    'restored_counts_json': restoredCountsJson,
    'started_at': startedAt,
    'finished_at': finishedAt,
    'error': error,
  };

  static RestoreLog fromRow(Map<String, Object?> row) => RestoreLog(
    id: row['id']! as String,
    backupId: row['backup_id'] as String?,
    mode: (row['mode'] as String?) ?? 'new_copy',
    status: row['status']! as String,
    previewJson: (row['preview_json'] as String?) ?? '{}',
    isCompatible: ((row['is_compatible'] as int?) ?? 0) != 0,
    isSpaceOk: ((row['is_space_ok'] as int?) ?? 0) != 0,
    safetyBackupId: row['safety_backup_id'] as String?,
    restoredCountsJson: (row['restored_counts_json'] as String?) ?? '{}',
    startedAt: row['started_at']! as int,
    finishedAt: row['finished_at'] as int?,
    error: row['error'] as String?,
  );
}

/// 恢复前检查结果：三项都过才允许落地
class RestorePrecheck {
  RestorePrecheck({
    required this.backupId,
    required this.backupSchemaVersion,
    required this.currentSchemaVersion,
    required this.isCompatible,
    required this.isSpaceOk,
    required this.itemCountsJson,
  });

  final String backupId;
  final String backupSchemaVersion;
  final String currentSchemaVersion;
  final bool isCompatible;
  final bool isSpaceOk;
  final String itemCountsJson;

  bool get canProceed => isCompatible && isSpaceOk;

  Map<String, Object?> toJson() => <String, Object?>{
    'backup_id': backupId,
    'backup_schema_version': backupSchemaVersion,
    'current_schema_version': currentSchemaVersion,
    'is_compatible': isCompatible,
    'is_space_ok': isSpaceOk,
    'item_counts_json': itemCountsJson,
  };
}

/// 备份验证结果
class BackupVerification {
  BackupVerification({
    required this.manifestId,
    required this.sha256Matches,
    required this.decrypted,
    required this.itemCountsJson,
  });

  final String manifestId;
  final bool sha256Matches;
  final bool decrypted;
  final String itemCountsJson;
}

// ── 备份快照（逻辑导出）────────────────────────────────────────────────────

/// 单元格值：与 SQLite 五种存储类别一一对应（BLOB 存 base64）
sealed class BackupValue {
  const BackupValue();

  Object? toSql() => switch (this) {
    BackupNullValue _ => null,
    BackupIntegerValue v => v.value,
    BackupRealValue v => v.value,
    BackupTextValue v => v.value,
    BackupBlobValue v => v.value, // 已还原为字节列表
  };

  dynamic toJson() => switch (this) {
    BackupNullValue _ => null,
    BackupIntegerValue v => v.value,
    BackupRealValue v => v.value,
    BackupTextValue v => v.value,
    // BLOB 用标记对象编码，避免与普通文本歧义
    BackupBlobValue v => <String, String>{'__blob': v.base64},
  };

  /// 从 JSON 动态值还原
  static BackupValue fromJson(Object? raw) {
    if (raw == null) return const BackupNullValue();
    if (raw is int) return BackupIntegerValue(raw);
    if (raw is double) return BackupRealValue(raw);
    if (raw is Map<String, dynamic> && raw['__blob'] is String) {
      return BackupBlobValue.fromBase64(raw['__blob'] as String);
    }
    return BackupTextValue(raw.toString());
  }

  /// 从 SQLite 行值还原
  static BackupValue fromSql(Object? raw) {
    if (raw == null) return const BackupNullValue();
    if (raw is int) return BackupIntegerValue(raw);
    if (raw is double) return BackupRealValue(raw);
    if (raw is List<int>) return BackupBlobValue.fromBytes(raw);
    return BackupTextValue(raw.toString());
  }
}

class BackupNullValue extends BackupValue {
  const BackupNullValue();
}

class BackupIntegerValue extends BackupValue {
  const BackupIntegerValue(this.value);
  final int value;
}

class BackupRealValue extends BackupValue {
  const BackupRealValue(this.value);
  final double value;
}

class BackupTextValue extends BackupValue {
  const BackupTextValue(this.value);
  final String value;
}

class BackupBlobValue extends BackupValue {
  BackupBlobValue.fromBytes(List<int> bytes) : value = bytes;
  BackupBlobValue.fromBase64(String base64) : value = base64Decode(base64);
  final List<int> value;

  String get base64 => base64Encode(value);
}

/// 一张表的快照
class BackupTableSnapshot {
  BackupTableSnapshot({required this.name, required this.columns, required this.rows});

  final String name;
  final List<String> columns;
  final List<List<BackupValue>> rows;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'columns': columns,
    'rows': rows.map((List<BackupValue> row) => row.map((BackupValue v) => v.toJson()).toList()).toList(),
  };

  static BackupTableSnapshot fromJson(Map<String, Object?> json) {
    return BackupTableSnapshot(
      name: json['name']! as String,
      columns: (json['columns']! as List<dynamic>).cast<String>(),
      rows: (json['rows']! as List<dynamic>)
          .map(
            (dynamic row) =>
                (row! as List<dynamic>).map((dynamic v) => BackupValue.fromJson(v)).toList(),
          )
          .toList(),
    );
  }
}

/// 备份快照：一份完整逻辑导出
class BackupSnapshot {
  static const int currentFormat = 1;

  BackupSnapshot({
    this.format = currentFormat,
    required this.schemaVersion,
    required this.appVersion,
    required this.createdAt,
    required this.tables,
    required this.counts,
    this.sourceDeviceId,
  });

  final int format;
  final String schemaVersion;
  final String appVersion;
  final int createdAt;
  final List<BackupTableSnapshot> tables;
  /// 表名 → 行数（恢复预览与完整性核对）
  final Map<String, int> counts;
  /// 产生该备份的设备标识；历史备份为 null
  final String? sourceDeviceId;

  int get totalRows => counts.values.fold(0, (int sum, int n) => sum + n);

  String encode() => jsonEncode(<String, Object?>{
    'format': format,
    'schema_version': schemaVersion,
    'app_version': appVersion,
    'created_at': createdAt,
    'tables': tables.map((BackupTableSnapshot t) => t.toJson()).toList(),
    'counts': counts,
    'source_device_id': sourceDeviceId,
  });

  static BackupSnapshot decode(String json) {
    final Map<String, Object?> root = jsonDecode(json) as Map<String, Object?>;
    return BackupSnapshot(
      format: (root['format'] as int?) ?? currentFormat,
      schemaVersion: root['schema_version']! as String,
      appVersion: (root['app_version'] as String?) ?? '',
      createdAt: (root['created_at'] as int?) ?? 0,
      tables: (root['tables']! as List<dynamic>)
          .map((dynamic t) => BackupTableSnapshot.fromJson(t! as Map<String, Object?>))
          .toList(),
      counts: ((root['counts'] ?? <String, Object?>{}) as Map).cast<String, int>(),
      sourceDeviceId: root['source_device_id'] as String?,
    );
  }
}

// ── 错误 ───────────────────────────────────────────────────────────────────

/// 备份错误（中文可直接展示）
class BackupError implements Exception {
  BackupError(this.message);
  final String message;

  static BackupError get notFound => BackupError('备份记录不存在');
  static BackupError incompatibleSchema(String version) =>
      BackupError('备份版本不兼容：$version');
  static BackupError get insufficientSpace => BackupError('可用空间不足');

  @override
  String toString() => message;
}

/// 备份容器/加解密错误
class BackupCipherError implements Exception {
  BackupCipherError(this.message);
  final String message;

  static BackupError get badMagic => BackupError('不是大肥鱼备份文件');
  static BackupCipherError unsupportedVersion(int version) =>
      BackupCipherError('备份容器版本不支持：$version');
  static BackupCipherError get truncatedContainer => BackupCipherError('备份文件被截断');
  static BackupCipherError get authenticationFailed =>
      BackupCipherError('备份校验失败：密钥不对或文件已被篡改');
  static BackupCipherError get cryptoUnavailable => BackupCipherError('当前平台没有可用的加密实现');
  static BackupCipherError invalidKeyLength(int length) =>
      BackupCipherError('密钥长度非法：$length 字节（需要 32 字节）');

  @override
  String toString() => message;
}

/// 备份快照结构错误
class BackupSnapshotError implements Exception {
  BackupSnapshotError(this.message);
  final String message;

  static BackupSnapshotError unsupportedFormat(int format) =>
      BackupSnapshotError('备份快照格式不支持：$format');
  static BackupSnapshotError unknownTable(String name) =>
      BackupSnapshotError('备份包含未知表：$name');
  static BackupSnapshotError columnMismatch(String table) =>
      BackupSnapshotError('恢复表结构不匹配：$table');
  static BackupSnapshotError rowWidthMismatch(String table) =>
      BackupSnapshotError('恢复行宽与列数不一致：$table');

  @override
  String toString() => message;
}

/// 恢复门禁错误（D72）：硬拒绝或需要用户确认
class RestoreGuardError implements Exception {
  RestoreGuardError.blocked(this.message);
  RestoreGuardError.confirmationRequired(this.message);
  final String message;

  @override
  String toString() => message;
}

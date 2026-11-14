import Foundation
import GRDB
import DFCore

/// 备份清单与恢复日志仓储（W9）。
///
/// 只负责"记录事实"：文件落盘/加密/解密由上层 `BackupService` 完成，
/// 这里保证清单、校验和、恢复结果与保留策略可追溯。
public struct GRDBBackupRepository: BackupRepository, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    private static let columns = """
    id, kind, scope, status, schema_version, app_version, file_name, rel_path, byte_size,
    sha256, is_encrypted, encryption_hint, item_counts_json, note, created_at, finished_at,
    verified_at, retention_until
    """

    public func create(
        kind: BackupKind,
        scope: String,
        schemaVersion: String,
        appVersion: String,
        fileName: String,
        relPath: String,
        isEncrypted: Bool,
        encryptionHint: String?,
        note: String?,
        at millis: Int64
    ) async throws -> BackupManifest {
        let id = UUID().uuidString
        do {
            try await database.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO backup_manifests
                        (id, kind, scope, status, schema_version, app_version, file_name, rel_path,
                         byte_size, sha256, is_encrypted, encryption_hint, item_counts_json, note,
                         created_at)
                    VALUES (?, ?, ?, 'pending', ?, ?, ?, ?, 0, NULL, ?, ?, '{}', ?, ?)
                    """,
                    arguments: [
                        id, kind.rawValue, scope, schemaVersion, appVersion, fileName, relPath,
                        isEncrypted ? 1 : 0, encryptionHint, note, millis
                    ]
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
        guard let manifest = try await manifest(id: id) else { throw BackupError.notFound }
        return manifest
    }

    public func markFinished(
        id: String,
        byteSize: Int64,
        sha256: String?,
        itemCountsJSON: String,
        at millis: Int64
    ) async throws {
        try await update(
            id: id,
            sql: """
            UPDATE backup_manifests
            SET status = 'completed', byte_size = ?, sha256 = ?, item_counts_json = ?,
                finished_at = ?
            WHERE id = ?
            """,
            arguments: [byteSize, sha256, itemCountsJSON, millis, id]
        )
    }

    public func markFailed(id: String, at millis: Int64) async throws {
        try await update(
            id: id,
            sql: "UPDATE backup_manifests SET status = 'failed', finished_at = ? WHERE id = ?",
            arguments: [millis, id]
        )
    }

    public func markVerified(id: String, at millis: Int64) async throws {
        try await update(
            id: id,
            sql: """
            UPDATE backup_manifests SET status = 'verified', verified_at = ? WHERE id = ?
            """,
            arguments: [millis, id]
        )
    }

    public func manifest(id: String) async throws -> BackupManifest? {
        do {
            return try await database.dbQueue.read { db in
                try Row.fetchOne(
                    db,
                    sql: "SELECT \(Self.columns) FROM backup_manifests WHERE id = ?",
                    arguments: [id]
                ).map(Self.decode)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func manifests(kind: BackupKind?, limit: Int) async throws -> [BackupManifest] {
        do {
            return try await database.dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT \(Self.columns) FROM backup_manifests
                    WHERE (? IS NULL OR kind = ?)
                    ORDER BY created_at DESC, id ASC
                    LIMIT ?
                    """,
                    arguments: [kind?.rawValue, kind?.rawValue, min(max(limit, 1), 200)]
                ).map(Self.decode)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func latest(kind: BackupKind?) async throws -> BackupManifest? {
        try await manifests(kind: kind, limit: 1).first
    }

    public func delete(id: String) async throws {
        do {
            try await database.write { db in
                try db.execute(sql: "DELETE FROM backup_manifests WHERE id = ?", arguments: [id])
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func prunable(keepCount: Int, at millis: Int64) async throws -> [BackupManifest] {
        do {
            return try await database.dbQueue.read { db in
                let keep = min(max(keepCount, 0), 100)
                return try Row.fetchAll(
                    db,
                    sql: """
                    SELECT \(Self.columns) FROM backup_manifests
                    WHERE status IN ('completed', 'failed')
                      AND kind NOT IN ('safety')
                    ORDER BY created_at DESC, id ASC
                    LIMIT -1 OFFSET ?
                    """,
                    arguments: [keep]
                ).map(Self.decode)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func startRestore(
        backupID: String?,
        mode: String,
        previewJSON: String,
        isCompatible: Bool,
        isSpaceOK: Bool,
        safetyBackupID: String?,
        at millis: Int64
    ) async throws -> RestoreLog {
        let id = UUID().uuidString
        do {
            try await database.write { db in
                let running = try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM restore_logs WHERE status IN ('pending', 'running')"
                ) ?? 0
                guard running == 0 else { throw BackupError.restoreAlreadyRunning }
                guard isCompatible else {
                    throw BackupError.incompatibleSchema(backupID ?? "unknown")
                }
                guard isSpaceOK else { throw BackupError.insufficientSpace }

                try db.execute(
                    sql: """
                    INSERT INTO restore_logs
                        (id, backup_id, mode, status, preview_json, is_compatible, is_space_ok,
                         safety_backup_id, restored_counts_json, started_at)
                    VALUES (?, ?, ?, 'running', ?, 1, 1, ?, '{}', ?)
                    """,
                    arguments: [id, backupID, mode, previewJSON, safetyBackupID, millis]
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
        return RestoreLog(
            id: id, backupID: backupID, mode: mode, status: "running",
            previewJSON: previewJSON, isCompatible: isCompatible, isSpaceOK: isSpaceOK,
            safetyBackupID: safetyBackupID, restoredCountsJSON: "{}",
            startedAt: millis, finishedAt: nil, error: nil
        )
    }

    public func finishRestore(
        id: String,
        status: String,
        restoredCountsJSON: String,
        error: String?,
        at millis: Int64
    ) async throws {
        try await update(
            id: id,
            sql: """
            UPDATE restore_logs
            SET status = ?, restored_counts_json = ?, error = ?, finished_at = ?
            WHERE id = ?
            """,
            arguments: [status, restoredCountsJSON, error, millis, id],
            table: "restore_logs"
        )
    }

    public func restoreLogs(limit: Int) async throws -> [RestoreLog] {
        do {
            return try await database.dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, backup_id, mode, status, preview_json, is_compatible, is_space_ok,
                           safety_backup_id, restored_counts_json, started_at, finished_at, error
                    FROM restore_logs ORDER BY started_at DESC, id ASC LIMIT ?
                    """,
                    arguments: [min(max(limit, 1), 200)]
                ).map { row in
                    RestoreLog(
                        id: try row.decode(String.self, forColumn: "id"),
                        backupID: String.fromDatabaseValue(row["backup_id"]),
                        mode: try row.decode(String.self, forColumn: "mode"),
                        status: try row.decode(String.self, forColumn: "status"),
                        previewJSON: try row.decode(String.self, forColumn: "preview_json"),
                        isCompatible: (Int.fromDatabaseValue(row["is_compatible"]) ?? 0) != 0,
                        isSpaceOK: (Int.fromDatabaseValue(row["is_space_ok"]) ?? 0) != 0,
                        safetyBackupID: String.fromDatabaseValue(row["safety_backup_id"]),
                        restoredCountsJSON: try row.decode(String.self, forColumn: "restored_counts_json"),
                        startedAt: try row.decode(Int64.self, forColumn: "started_at"),
                        finishedAt: Int64.fromDatabaseValue(row["finished_at"]),
                        error: String.fromDatabaseValue(row["error"])
                    )
                }
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func totalBytes() async throws -> Int64 {
        do {
            return try await database.dbQueue.read { db in
                try Int64.fetchOne(
                    db,
                    sql: """
                    SELECT COALESCE(SUM(byte_size), 0) FROM backup_manifests
                    WHERE status IN ('completed', 'verified')
                    """
                ) ?? 0
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    // MARK: - 内部

    private func update(
        id: String,
        sql: String,
        arguments: StatementArguments,
        table: String = "backup_manifests"
    ) async throws {
        do {
            try await database.write { db in
                guard try Bool.fetchOne(
                    db,
                    sql: "SELECT 1 FROM \(table) WHERE id = ?",
                    arguments: [id]
                ) != nil else {
                    throw BackupError.notFound
                }
                try db.execute(sql: sql, arguments: arguments)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    private static func decode(_ row: Row) throws -> BackupManifest {
        BackupManifest(
            id: try row.decode(String.self, forColumn: "id"),
            kind: BackupKind(rawValue: try row.decode(String.self, forColumn: "kind")) ?? .manual,
            scope: try row.decode(String.self, forColumn: "scope"),
            status: BackupStatus(rawValue: try row.decode(String.self, forColumn: "status")) ?? .pending,
            schemaVersion: try row.decode(String.self, forColumn: "schema_version"),
            appVersion: try row.decode(String.self, forColumn: "app_version"),
            fileName: try row.decode(String.self, forColumn: "file_name"),
            relPath: try row.decode(String.self, forColumn: "rel_path"),
            byteSize: try row.decode(Int64.self, forColumn: "byte_size"),
            sha256: String.fromDatabaseValue(row["sha256"]),
            isEncrypted: (Int.fromDatabaseValue(row["is_encrypted"]) ?? 1) != 0,
            encryptionHint: String.fromDatabaseValue(row["encryption_hint"]),
            itemCountsJSON: try row.decode(String.self, forColumn: "item_counts_json"),
            note: String.fromDatabaseValue(row["note"]),
            createdAt: try row.decode(Int64.self, forColumn: "created_at"),
            finishedAt: Int64.fromDatabaseValue(row["finished_at"]),
            verifiedAt: Int64.fromDatabaseValue(row["verified_at"]),
            retentionUntil: Int64.fromDatabaseValue(row["retention_until"])
        )
    }
}

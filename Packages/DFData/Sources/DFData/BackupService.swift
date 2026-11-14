import Foundation
import GRDB
import DFCore

/// 备份验证结果。
public struct BackupVerification: Sendable, Equatable {
    public var manifestID: String
    public var sha256Matches: Bool
    public var decrypted: Bool
    public var itemCountsJSON: String

    public init(manifestID: String, sha256Matches: Bool, decrypted: Bool, itemCountsJSON: String) {
        self.manifestID = manifestID
        self.sha256Matches = sha256Matches
        self.decrypted = decrypted
        self.itemCountsJSON = itemCountsJSON
    }
}

/// 备份与恢复的落地实现（W9）。
///
/// 边界：
/// - 备份文件默认加密（AES-256-GCM 容器），密钥只存在本地 Keychain/钥匙串实现里；
/// - 明文导出必须由调用方显式 `encrypted: false`，UI 负责二次确认与风险提示；
/// - 恢复前先做版本兼容与空间检查，并**自动生成安全备份**；
/// - 恢复在一个事务内完成，任何失败整体回滚，原库不受影响；
/// - 恢复后重建记忆/消息/日记三套全文索引。
public final class BackupService: @unchecked Sendable {
    /// 逻辑导出/恢复的表顺序（父表在前；恢复时按相反顺序清空）
    public static let tableOrder: [String] = [
        "settings",
        "personas",
        "persona_items",
        "persona_versions",
        "conversations",
        "messages",
        "memories",
        "memory_sources",
        "memory_versions",
        "diary_entries",
        "diary_entry_versions"
    ]

    private let database: AppDatabase
    private let repository: GRDBBackupRepository
    private let cipher: BackupCipher?
    private let keyStore: BackupKeyStoring
    private let appVersion: String
    private let now: @Sendable () -> Int64
    private let fileManager = FileManager.default

    public init(
        database: AppDatabase,
        keyStore: BackupKeyStoring,
        cipher: BackupCipher? = BackupCipherFactory.makeDefault(),
        appVersion: String = "0.1.0",
        now: @escaping @Sendable () -> Int64 = { Clock.nowMillis() }
    ) {
        self.database = database
        self.repository = GRDBBackupRepository(database: database)
        self.keyStore = keyStore
        self.cipher = cipher
        self.appVersion = appVersion
        self.now = now
    }

    public var backupsDirectory: URL {
        database.paths.workspace.appendingPathComponent("Backups", isDirectory: true)
    }

    // MARK: - 导出

    public func exportSnapshot(at millis: Int64? = nil) async throws -> BackupSnapshot {
        let timestamp = millis ?? now()
        let schemaVersion = database.currentSchemaVersion

        let tables = try await database.dbQueue.read { db -> [BackupTableSnapshot] in
            var result: [BackupTableSnapshot] = []
            for table in Self.tableOrder {
                guard try db.tableExists(table) else { continue }
                let columns = try db.columns(in: table).map(\.name)
                guard !columns.isEmpty else { continue }
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT \(columns.joined(separator: ",")) FROM \(table)"
                )
                result.append(
                    BackupTableSnapshot(
                        name: table,
                        columns: columns,
                        rows: rows.map { Self.encode(row: $0, columns: columns) }
                    )
                )
            }
            return result
        }

        var counts: [String: Int] = [:]
        for table in tables { counts[table.name] = table.rows.count }

        return BackupSnapshot(
            schemaVersion: schemaVersion,
            appVersion: appVersion,
            createdAt: timestamp,
            tables: tables,
            counts: counts
        )
    }

    // MARK: - 创建备份

    @discardableResult
    public func createBackup(
        kind: BackupKind,
        scope: String = "all",
        note: String? = nil,
        encrypted: Bool = true,
        at millis: Int64? = nil
    ) async throws -> BackupManifest {
        let timestamp = millis ?? now()
        let snapshot = try await exportSnapshot(at: timestamp)
        let encoder = JSONEncoder()
        let plaintext = try encoder.encode(snapshot)
        let countsJSON = String(data: try encoder.encode(snapshot.counts), encoding: .utf8) ?? "{}"

        let payload: Data
        var hint: String?
        if encrypted {
            guard let cipher else { throw BackupCipherError.cryptoUnavailable }
            let key = try keyStore.loadOrCreateKey()
            payload = try BackupContainer.seal(plaintext, key: key, cipher: cipher)
            hint = cipher.identifier
        } else {
            payload = plaintext
        }

        let directory = backupsDirectory
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = "dafeiyu-\(kind.rawValue)-\(timestamp).\(encrypted ? "dfbk" : "json")"
        let url = directory.appendingPathComponent(fileName)
        try payload.write(to: url, options: .atomic)

        let manifest = try await repository.create(
            kind: kind,
            scope: scope,
            schemaVersion: snapshot.schemaVersion,
            appVersion: appVersion,
            fileName: fileName,
            relPath: "Workspace/Backups/\(fileName)",
            isEncrypted: encrypted,
            encryptionHint: hint,
            note: note,
            at: timestamp
        )
        try await repository.markFinished(
            id: manifest.id,
            byteSize: Int64(payload.count),
            sha256: SHA256.hash(payload),
            itemCountsJSON: countsJSON,
            at: timestamp
        )
        return try await repository.manifest(id: manifest.id) ?? manifest
    }

    // MARK: - 读取 / 验证

    public func readSnapshot(manifestID: String) async throws -> BackupSnapshot {
        guard let manifest = try await repository.manifest(id: manifestID), manifest.isUsable else {
            throw BackupError.notFound
        }
        let url = backupsDirectory.appendingPathComponent(manifest.fileName)
        guard fileManager.fileExists(atPath: url.path) else { throw BackupError.notFound }
        let data = try Data(contentsOf: url)

        let plaintext: Data
        if manifest.isEncrypted {
            guard let cipher else { throw BackupCipherError.cryptoUnavailable }
            let key = try keyStore.loadOrCreateKey()
            plaintext = try BackupContainer.open(data, key: key, cipher: cipher)
        } else {
            plaintext = data
        }

        let snapshot = try JSONDecoder().decode(BackupSnapshot.self, from: plaintext)
        guard snapshot.format == BackupSnapshot.currentFormat else {
            throw BackupSnapshotError.unsupportedFormat(snapshot.format)
        }
        return snapshot
    }

    public func verify(manifestID: String) async throws -> BackupVerification {
        guard let manifest = try await repository.manifest(id: manifestID), manifest.isUsable else {
            throw BackupError.notFound
        }
        let url = backupsDirectory.appendingPathComponent(manifest.fileName)
        guard fileManager.fileExists(atPath: url.path) else { throw BackupError.notFound }
        let data = try Data(contentsOf: url)
        let sha = SHA256.hash(data)
        let matches = manifest.sha256.map { $0 == sha } ?? false

        var decrypted = false
        var countsJSON = manifest.itemCountsJSON
        if matches {
            let snapshot = try await readSnapshot(manifestID: manifestID)
            decrypted = true
            countsJSON = String(
                data: try JSONEncoder().encode(snapshot.counts),
                encoding: .utf8
            ) ?? countsJSON
            try await repository.markVerified(id: manifestID, at: now())
        }
        return BackupVerification(
            manifestID: manifestID,
            sha256Matches: matches,
            decrypted: decrypted,
            itemCountsJSON: countsJSON
        )
    }

    // MARK: - 恢复

    public func previewRestore(manifestID: String) async throws -> RestorePrecheck {
        guard let manifest = try await repository.manifest(id: manifestID), manifest.isUsable else {
            throw BackupError.notFound
        }
        let snapshot = try await readSnapshot(manifestID: manifestID)
        let current = database.currentSchemaVersion
        let compatible = snapshot.schemaVersion == current
        let free = availableBytes()
        let required = manifest.byteSize * 2 + 20 * 1024 * 1024
        let spaceOK = free.map { $0 > required } ?? true
        let countsJSON = String(data: try JSONEncoder().encode(snapshot.counts), encoding: .utf8) ?? "{}"

        return RestorePrecheck(
            backupID: manifestID,
            backupSchemaVersion: snapshot.schemaVersion,
            currentSchemaVersion: current,
            isCompatible: compatible,
            isSpaceOK: spaceOK,
            itemCountsJSON: countsJSON
        )
    }

    @discardableResult
    public func restore(
        manifestID: String,
        mode: String = "replace",
        at millis: Int64? = nil
    ) async throws -> RestoreLog {
        let timestamp = millis ?? now()
        let precheck = try await previewRestore(manifestID: manifestID)
        guard precheck.isCompatible else {
            throw BackupError.incompatibleSchema(precheck.backupSchemaVersion)
        }
        guard precheck.isSpaceOK else { throw BackupError.insufficientSpace }

        let snapshot = try await readSnapshot(manifestID: manifestID)

        // 恢复前必须留下安全备份：恢复失败或恢复结果不满意时可退回
        let safety = try await createBackup(
            kind: .safety,
            scope: "safety",
            note: "恢复前自动备份",
            encrypted: true,
            at: timestamp
        )
        let previewJSON = String(data: try JSONEncoder().encode(precheck), encoding: .utf8) ?? "{}"
        let log = try await repository.startRestore(
            backupID: manifestID,
            mode: mode,
            previewJSON: previewJSON,
            isCompatible: true,
            isSpaceOK: true,
            safetyBackupID: safety.id,
            at: timestamp
        )

        do {
            let counts = try await apply(snapshot: snapshot)
            let countsJSON = String(data: try JSONEncoder().encode(counts), encoding: .utf8) ?? "{}"
            try await repository.finishRestore(
                id: log.id,
                status: "completed",
                restoredCountsJSON: countsJSON,
                error: nil,
                at: timestamp
            )
        } catch {
            // 事务已整体回滚，原库保持恢复前状态
            try? await repository.finishRestore(
                id: log.id,
                status: "failed",
                restoredCountsJSON: "{}",
                error: String(describing: error),
                at: timestamp
            )
            throw error
        }

        let logs = try await repository.restoreLogs(limit: 20)
        return logs.first(where: { $0.id == log.id }) ?? log
    }

    // MARK: - 内部

    private func apply(snapshot: BackupSnapshot) async throws -> [String: Int] {
        let known = Set(Self.tableOrder)
        for table in snapshot.tables where !known.contains(table.name) {
            throw BackupSnapshotError.unknownTable(table.name)
        }

        return try await database.write { db in
            // 1. 先清空（子表在前），再按父表顺序写入
            for table in Self.tableOrder.reversed() {
                guard try db.tableExists(table) else { continue }
                try db.execute(sql: "DELETE FROM \(table)")
            }

            // 2. 写入
            var restored: [String: Int] = [:]
            for table in snapshot.tables {
                guard try db.tableExists(table.name) else {
                    throw BackupSnapshotError.unknownTable(table.name)
                }
                let existing = try db.columns(in: table.name).map(\.name)
                guard Set(existing).isSuperset(of: Set(table.columns)) else {
                    throw BackupSnapshotError.columnMismatch(table: table.name)
                }
                let columnList = table.columns.joined(separator: ",")
                let placeholders = table.columns.map { _ in "?" }.joined(separator: ",")
                for row in table.rows {
                    guard row.count == table.columns.count else {
                        throw BackupSnapshotError.rowWidthMismatch(table: table.name)
                    }
                    try db.execute(
                        sql: "INSERT INTO \(table.name) (\(columnList)) VALUES (\(placeholders))",
                        arguments: StatementArguments(row.map(\.databaseValue))
                    )
                }
                restored[table.name] = table.rows.count
            }

            // 3. 全文索引必须跟着重建，否则恢复后检索与数据不一致
            try Self.rebuildSearchIndexes(db)
            return restored
        }
    }

    private func availableBytes() -> Int64? {
        guard let attributes = try? fileManager.attributesOfFileSystem(forPath: database.paths.root.path),
              let free = attributes[.systemFreeSize] as? NSNumber else {
            return nil
        }
        return free.int64Value
    }

    private static func encode(row: Row, columns: [String]) -> [BackupValue] {
        columns.map { column in
            let raw = row[column] as? DatabaseValue ?? .null
            switch raw.storage {
            case .null: return .null
            case .int64(let value): return .integer(value)
            case .double(let value): return .real(value)
            case .string(let value): return .text(value)
            case .blob(let value): return .blob(value.base64EncodedString())
            }
        }
    }

    private static func rebuildSearchIndexes(_ db: Database) throws {
        if try db.tableExists("memory_fts") {
            try db.execute(sql: "DELETE FROM memory_fts")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, scope, title, content FROM memories WHERE deleted_at IS NULL"
            )
            for row in rows {
                let text = (String.fromDatabaseValue(row["title"]) ?? "")
                    + " " + (String.fromDatabaseValue(row["content"]) ?? "")
                try db.execute(
                    sql: "INSERT INTO memory_fts (memory_id, scope, text_bigram) VALUES (?, ?, ?)",
                    arguments: [
                        String.fromDatabaseValue(row["id"]),
                        String.fromDatabaseValue(row["scope"]),
                        V2Memory.bigram(text)
                    ]
                )
            }
        }

        if try db.tableExists("message_fts") {
            try db.execute(sql: "DELETE FROM message_fts")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, conversation_id, text FROM messages WHERE deleted_at IS NULL"
            )
            for row in rows {
                try db.execute(
                    sql: "INSERT INTO message_fts (message_id, conversation_id, text_bigram) VALUES (?, ?, ?)",
                    arguments: [
                        String.fromDatabaseValue(row["id"]),
                        String.fromDatabaseValue(row["conversation_id"]),
                        V2Memory.bigram(String.fromDatabaseValue(row["text"]) ?? "")
                    ]
                )
            }
        }

        if try db.tableExists("diary_fts") {
            try db.execute(sql: "DELETE FROM diary_fts")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, title, content FROM diary_entries WHERE deleted_at IS NULL"
            )
            for row in rows {
                let text = (String.fromDatabaseValue(row["title"]) ?? "")
                    + " " + (String.fromDatabaseValue(row["content"]) ?? "")
                try db.execute(
                    sql: "INSERT INTO diary_fts (diary_id, text_bigram) VALUES (?, ?)",
                    arguments: [String.fromDatabaseValue(row["id"]), V2Memory.bigram(text)]
                )
            }
        }
    }
}

private extension BackupValue {
    var databaseValue: DatabaseValue {
        switch self {
        case .null: return .null
        case .integer(let value): return value.databaseValue
        case .real(let value): return value.databaseValue
        case .text(let value): return value.databaseValue
        case .blob(let base64):
            return Data(base64Encoded: base64)?.databaseValue ?? .null
        }
    }
}

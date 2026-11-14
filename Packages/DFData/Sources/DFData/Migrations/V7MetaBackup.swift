import Foundation
import GRDB
import DFCore

/// `v7_meta_backup` 迁移：备份清单 + 恢复日志 + 升级记录 + 附件软删列。
///
/// 边界（决策 33、34、67、72 / W1-7、W9-2、W9-3）：
/// - 只做 DDL 与"新列默认值"，**不修改任何历史行的既有内容**；
/// - 不写入任何备份、恢复或升级记录：事实必须来自真实执行，不允许预置"已备份"；
/// - 附件只加软删列，历史附件保持 `deleted_at IS NULL`（视为未删除）；
/// - 恢复日志必须能表达"失败不破坏现库"：`safety_backup_id` 与 `rolled_back` 状态缺一不可。
enum V7MetaBackup {
    /// 迁移耗时上限（秒）：只有 DDL 与小表结构校验
    static let timeLimit: TimeInterval = 30

    /// 本迁移新增的表
    static let newTables = [
        "backup_manifests",
        "restore_logs",
        "upgrade_records"
    ]

    /// 本迁移新增的索引
    static let newIndexes = [
        "ix_backup_manifests_time",
        "ix_backup_manifests_status",
        "ix_restore_logs_backup",
        "ix_restore_logs_status",
        "ix_upgrade_records_time",
        "ix_attachments_deleted"
    ]

    /// `attachments` 在 v6 结束时的列（仅作验收比对基线，顺序固定）
    static let legacyAttachmentColumns = [
        "id", "sha256", "kind", "rel_path", "byte_size", "mime", "created_at"
    ]

    /// 本迁移追加到 `attachments` 的列
    static let newAttachmentColumns = ["deleted_at", "deleted_reason"]

    static func migrate(_ db: Database) throws {
        let startedAt = Date()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let batch = "V2-v7_meta_backup-\(now)"

        // 0. 前置断言
        try assertUpgradable(db)

        // 1. 迁移前快照
        let messageFingerprintBefore = try V3Chat.messageFingerprint(db)
        let messagesBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? 0
        let personaFingerprintBefore = try V4Persona.itemFingerprint(db)
        let attachmentRowsBefore = try attachmentFingerprint(db)
        let attachmentsBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM attachments") ?? 0
        let columnsBefore = try attachmentColumns(db)
        let previous = try previousMeta(db)

        // 2. 附件加列（只改 schema，不重写历史行）
        try addAttachmentColumns(db)

        // 3. 新表与索引
        try createTables(db)
        try createIndexes(db)

        // 4. 哨兵：新表可读写，随后清理
        try sentinelRoundTrip(db, now: now)

        // 5. 校验：历史行不变、附件未被误删、记录表为空
        try validate(
            db,
            messageFingerprintBefore: messageFingerprintBefore,
            messagesBefore: messagesBefore,
            personaFingerprintBefore: personaFingerprintBefore,
            attachmentRowsBefore: attachmentRowsBefore,
            attachmentsBefore: attachmentsBefore,
            columnsBefore: columnsBefore
        )

        // 6. schema_meta
        try writeMeta(db, now: now, batch: batch, previous: previous)

        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed <= timeLimit else {
            throw DFError.database(
                String(format: "v7_meta_backup 迁移耗时 %.1fs，超过 %.0f 秒上限", elapsed, timeLimit)
            )
        }
    }

    // MARK: - 0. 前置断言

    private static func assertUpgradable(_ db: Database) throws {
        guard let version = try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion) else {
            throw DFError.database("v7_meta_backup 需要 schema_meta.schema_version，当前缺失")
        }
        guard version == MigrationID.v6_character.rawValue else {
            throw DFError.database(
                "v7_meta_backup 只能从 \(MigrationID.v6_character.rawValue) 升级，当前为 \(version)"
            )
        }

        let quoted = newTables.map { "'\($0)'" }.joined(separator: ",")
        let existing = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN (\(quoted))"
        ) ?? 0
        guard existing == 0 else {
            throw DFError.database("v7_meta_backup 新表已存在，不可重复执行")
        }

        guard !(try hasColumn(db, table: "attachments", column: "deleted_at")) else {
            throw DFError.database("attachments.deleted_at 已存在，v7_meta_backup 不可重复执行")
        }
    }

    private static func hasColumn(_ db: Database, table: String, column: String) throws -> Bool {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        return try rows.contains { try $0.decode(String.self, forColumn: "name") == column }
    }

    // MARK: - 1. 快照

    private static func attachmentColumns(_ db: Database) throws -> [String] {
        try Row.fetchAll(db, sql: "PRAGMA table_info(attachments)").map {
            try $0.decode(String.self, forColumn: "name")
        }
    }

    /// 历史附件逐行指纹：既有 7 列不得被本迁移改动
    static func attachmentFingerprint(_ db: Database) throws -> String {
        let columns = legacyAttachmentColumns.map { "quote(\($0))" }.joined(separator: " || char(31) || ")
        let lines = try String.fetchAll(
            db,
            sql: "SELECT \(columns) AS line FROM attachments ORDER BY id"
        )
        return SHA256.hash(lines.joined(separator: "\u{1E}"))
    }

    private static func previousMeta(_ db: Database) throws -> [String: String] {
        var result: [String: String] = [:]
        for key in [SchemaMetaKey.schemaVersion, SchemaMetaKey.migrationBatch, SchemaMetaKey.migratedAt] {
            if let value = try SchemaMeta.value(db, key: key) {
                result[key] = value
            }
        }
        return result
    }

    // MARK: - 2. 附件加列

    /// 软删：历史附件一律视为未删除，不得在迁移里推断"已清理"
    private static func addAttachmentColumns(_ db: Database) throws {
        let statements = [
            "ALTER TABLE attachments ADD COLUMN deleted_at INTEGER",
            "ALTER TABLE attachments ADD COLUMN deleted_reason TEXT"
        ]
        for statement in statements {
            try db.execute(sql: statement)
        }
    }

    // MARK: - 3. 建表与索引

    private static func createTables(_ db: Database) throws {
        // 备份清单：一份备份一行，校验和与加密标记必须落库
        try db.execute(sql: """
        CREATE TABLE backup_manifests (
            id               TEXT PRIMARY KEY,
            kind             TEXT NOT NULL DEFAULT 'manual',
            scope            TEXT NOT NULL DEFAULT 'full',
            status           TEXT NOT NULL DEFAULT 'pending',
            schema_version   TEXT NOT NULL,
            app_version      TEXT NOT NULL DEFAULT '',
            file_name        TEXT NOT NULL,
            rel_path         TEXT NOT NULL,
            byte_size        INTEGER NOT NULL DEFAULT 0,
            sha256           TEXT,
            is_encrypted     INTEGER NOT NULL DEFAULT 1,
            encryption_hint  TEXT,
            item_counts_json TEXT NOT NULL DEFAULT '{}',
            note             TEXT,
            created_at       INTEGER NOT NULL,
            finished_at      INTEGER,
            verified_at      INTEGER,
            retention_until  INTEGER
        )
        """)

        // 恢复日志：必须能表达"失败不破坏现库"
        try db.execute(sql: """
        CREATE TABLE restore_logs (
            id                  TEXT PRIMARY KEY,
            backup_id           TEXT REFERENCES backup_manifests(id) ON DELETE SET NULL,
            mode                TEXT NOT NULL DEFAULT 'new_copy',
            status              TEXT NOT NULL DEFAULT 'pending',
            preview_json        TEXT NOT NULL DEFAULT '{}',
            is_compatible       INTEGER NOT NULL DEFAULT 0,
            is_space_ok         INTEGER NOT NULL DEFAULT 0,
            safety_backup_id    TEXT REFERENCES backup_manifests(id) ON DELETE SET NULL,
            restored_counts_json TEXT NOT NULL DEFAULT '{}',
            started_at          INTEGER NOT NULL,
            finished_at         INTEGER,
            error               TEXT
        )
        """)

        // 升级记录：每次启动升级或重试都要留痕，供"失败恢复/回退"排查
        try db.execute(sql: """
        CREATE TABLE upgrade_records (
            id                     TEXT PRIMARY KEY,
            from_version           TEXT NOT NULL,
            to_version             TEXT NOT NULL,
            batch                  TEXT NOT NULL DEFAULT '',
            status                 TEXT NOT NULL DEFAULT 'running',
            pre_upgrade_backup_id  TEXT REFERENCES backup_manifests(id) ON DELETE SET NULL,
            integrity_json         TEXT NOT NULL DEFAULT '{}',
            error                  TEXT,
            started_at             INTEGER NOT NULL,
            finished_at            INTEGER
        )
        """)
    }

    private static func createIndexes(_ db: Database) throws {
        let statements = [
            "CREATE INDEX ix_backup_manifests_time ON backup_manifests(created_at)",
            "CREATE INDEX ix_backup_manifests_status ON backup_manifests(status, created_at)",
            "CREATE INDEX ix_restore_logs_backup ON restore_logs(backup_id, started_at)",
            "CREATE INDEX ix_restore_logs_status ON restore_logs(status, started_at)",
            "CREATE INDEX ix_upgrade_records_time ON upgrade_records(started_at)",
            "CREATE INDEX ix_attachments_deleted ON attachments(deleted_at)"
        ]
        for statement in statements {
            try db.execute(sql: statement)
        }
    }

    // MARK: - 4. 哨兵

    /// 用一份临时备份 + 恢复日志 + 升级记录验证新表可写，随后全部删除；
    /// 另用一条临时附件验证新列可写。
    private static func sentinelRoundTrip(_ db: Database, now: Int64) throws {
        let backupID = "__v7_sentinel_backup__"

        try db.execute(
            sql: """
            INSERT INTO backup_manifests
                (id, kind, scope, status, schema_version, file_name, rel_path, created_at)
            VALUES (?, 'manual', 'full', 'completed', ?, 'sentinel.zip', 'backup/sentinel.zip', ?)
            """,
            arguments: [backupID, MigrationID.v6_character.rawValue, now]
        )
        try db.execute(
            sql: """
            INSERT INTO restore_logs (id, backup_id, mode, status, started_at)
            VALUES ('__v7_sentinel_restore__', ?, 'new_copy', 'completed', ?)
            """,
            arguments: [backupID, now]
        )
        try db.execute(
            sql: """
            INSERT INTO upgrade_records
                (id, from_version, to_version, batch, status, started_at)
            VALUES ('__v7_sentinel_upgrade__', ?, ?, 'sentinel', 'succeeded', ?)
            """,
            arguments: [MigrationID.v6_character.rawValue, MigrationID.v7_meta_backup.rawValue, now]
        )
        try db.execute(
            sql: """
            INSERT INTO attachments (id, sha256, kind, rel_path, byte_size, mime, created_at, deleted_at)
            VALUES ('__v7_sentinel_att__', '__v7_sentinel_sha__', 'image', 'sentinel.png', 1, 'image/png', ?, ?)
            """,
            arguments: [now, now]
        )

        let written = try Int.fetchOne(
            db,
            sql: """
            SELECT (SELECT count(*) FROM backup_manifests) +
                   (SELECT count(*) FROM restore_logs) +
                   (SELECT count(*) FROM upgrade_records) +
                   (SELECT count(*) FROM attachments WHERE id = '__v7_sentinel_att__')
            """
        ) ?? 0

        try db.execute(sql: "DELETE FROM attachments WHERE id = '__v7_sentinel_att__'")
        try db.execute(sql: "DELETE FROM upgrade_records WHERE id = '__v7_sentinel_upgrade__'")
        try db.execute(sql: "DELETE FROM restore_logs WHERE id = '__v7_sentinel_restore__'")
        try db.execute(sql: "DELETE FROM backup_manifests WHERE id = ?", arguments: [backupID])

        guard written >= 4 else {
            throw DFError.database("v7_meta_backup 哨兵写入失败：新表或新列不可写")
        }
    }

    // MARK: - 5. 校验

    private static func validate(
        _ db: Database,
        messageFingerprintBefore: String,
        messagesBefore: Int,
        personaFingerprintBefore: String,
        attachmentRowsBefore: String,
        attachmentsBefore: Int,
        columnsBefore: [String]
    ) throws {
        let messageFingerprintAfter = try V3Chat.messageFingerprint(db)
        guard messageFingerprintAfter == messageFingerprintBefore else {
            throw DFError.database("v7_meta_backup 改动了历史消息内容（指纹不一致）")
        }
        let messagesAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? -1
        guard messagesAfter == messagesBefore else {
            throw DFError.database("v7_meta_backup 改变了消息行数：\(messagesBefore) → \(messagesAfter)")
        }
        let personaFingerprintAfter = try V4Persona.itemFingerprint(db)
        guard personaFingerprintAfter == personaFingerprintBefore else {
            throw DFError.database("v7_meta_backup 改动了人格条目内容（指纹不一致）")
        }

        let attachmentsAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM attachments") ?? -1
        guard attachmentsAfter == attachmentsBefore else {
            throw DFError.database("v7_meta_backup 改变了附件行数：\(attachmentsBefore) → \(attachmentsAfter)")
        }
        let attachmentRowsAfter = try attachmentFingerprint(db)
        guard attachmentRowsAfter == attachmentRowsBefore else {
            throw DFError.database("v7_meta_backup 改动了历史附件内容（指纹不一致）")
        }

        let columnsAfter = try attachmentColumns(db)
        let expectedCount = legacyAttachmentColumns.count + newAttachmentColumns.count
        guard columnsAfter.count == expectedCount else {
            throw DFError.database("v7_meta_backup 后 attachments 列数应为 \(expectedCount)，实际 \(columnsAfter.count)")
        }
        guard Array(columnsAfter.prefix(legacyAttachmentColumns.count)) == columnsBefore,
              Array(columnsAfter.prefix(legacyAttachmentColumns.count)) == legacyAttachmentColumns else {
            throw DFError.database("v7_meta_backup 改变了 attachments 既有列的顺序或名称")
        }
        guard Array(columnsAfter.suffix(newAttachmentColumns.count)) == newAttachmentColumns else {
            throw DFError.database("v7_meta_backup 追加的附件列与预期不一致：\(columnsAfter)")
        }

        // 历史附件不得被推断成"已删除"
        let deleted = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM attachments WHERE deleted_at IS NOT NULL OR deleted_reason IS NOT NULL"
        ) ?? -1
        guard deleted == 0 else {
            throw DFError.database("v7_meta_backup 不得为历史附件回填删除状态：\(deleted) 行")
        }

        // 记录类表必须为空：不允许预置"已备份/已恢复/已升级"的假事实
        for table in newTables {
            let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? -1
            guard count == 0 else {
                throw DFError.database("v7_meta_backup 不得预置数据：\(table) 有 \(count) 行")
            }
        }

        let quick = try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "unknown"
        guard quick.lowercased() == "ok" else {
            throw DFError.database("v7_meta_backup 迁移后 quick_check 失败：\(quick)")
        }
    }

    // MARK: - 6. schema_meta

    private static func writeMeta(
        _ db: Database,
        now: Int64,
        batch: String,
        previous: [String: String]
    ) throws {
        let appliedBefore = try SchemaMeta.appliedIdentifiers(db)
        let expected = try SchemaMeta.expectedPrefixIncluding(current: .v7_meta_backup, appliedBefore: appliedBefore)
        let digest = MigrationLedger.digest(prefix: expected)

        if let value = previous[SchemaMetaKey.schemaVersion] {
            try SchemaMeta.write(db, key: SchemaMetaKey.previousSchemaVersion, value: value, at: now)
        }
        if let value = previous[SchemaMetaKey.migrationBatch] {
            try SchemaMeta.write(db, key: SchemaMetaKey.previousMigrationBatch, value: value, at: now)
        }
        if let value = previous[SchemaMetaKey.migratedAt] {
            try SchemaMeta.write(db, key: SchemaMetaKey.previousMigratedAt, value: value, at: now)
        }

        try SchemaMeta.write(db, key: SchemaMetaKey.schemaVersion, value: MigrationID.v7_meta_backup.rawValue, at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.appliedPhase, value: "V2-P6", at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.expectedMigrations, value: String(expected.count), at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.migratedAt, value: String(now), at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.migrationBatch, value: batch, at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.ledgerDigest, value: digest, at: now)
    }
}

import Foundation
import GRDB
import DFCore

/// v15：表情包（内置 Emoji / 导入静态图与 GIF / 在线下载 / 收藏 / 最近使用）。
///
/// 只新建三张表与索引，**不修改任何历史行**：
/// - `sticker_packs`：表情包分组（来源、许可证、在线地址）；
/// - `stickers`：表情索引；图片/GIF 仍走 `attachments` 内容寻址，不复制文件；
/// - `sticker_usage`：使用记录，支撑"最近使用"。
///
/// 口径：
/// - 不为历史数据伪造任何表情行（迁移后三张表必须为空）；
/// - 语义描述字段默认为空，表示"尚未识别"，不预填猜测；
/// - 删除表情只软删索引，不删附件文件（文件清理由 D57 引用检查负责）。
enum V15Stickers {
    static let timeLimit: TimeInterval = 5

    static let newTables = ["sticker_packs", "stickers", "sticker_usage"]

    static func migrate(_ db: Database) throws {
        let startedAt = Date()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let batch = "V2-v15_stickers-\(now)"

        try assertUpgradable(db)

        let messagesBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? 0
        let attachmentsBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM attachments") ?? 0
        let memoriesBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM memories") ?? 0
        let previous = try previousMeta(db)

        try createTables(db)
        try createIndexes(db)
        try sentinelRoundTrip(db, now: now)

        let messagesAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? 0
        let attachmentsAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM attachments") ?? 0
        let memoriesAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM memories") ?? 0
        guard messagesBefore == messagesAfter else {
            throw DFError.database("v15_stickers 迁移改动了 messages 行数")
        }
        guard attachmentsBefore == attachmentsAfter else {
            throw DFError.database("v15_stickers 迁移改动了 attachments 行数")
        }
        guard memoriesBefore == memoriesAfter else {
            throw DFError.database("v15_stickers 迁移改动了 memories 行数")
        }
        // 不得预置任何表情数据（内置目录由启动引导写入，迁移本身不伪造）
        for table in newTables {
            let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? -1
            guard count == 0 else {
                throw DFError.database("v15_stickers 不得预置数据：\(table) 有 \(count) 行")
            }
        }

        try writeMeta(db, now: now, batch: batch, previous: previous)

        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed <= timeLimit else {
            throw DFError.database(
                String(format: "v15_stickers 迁移耗时 %.1fs，超过 %.0f 秒上限", elapsed, timeLimit)
            )
        }
    }

    // MARK: - 0. 前置断言

    private static func assertUpgradable(_ db: Database) throws {
        guard let version = try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion) else {
            throw DFError.database("v15_stickers 需要 schema_meta.schema_version，当前缺失")
        }
        guard version == MigrationID.v14_message_organization.rawValue else {
            throw DFError.database(
                "v15_stickers 只能从 \(MigrationID.v14_message_organization.rawValue) 升级，当前为 \(version)"
            )
        }
        guard try db.tableExists("attachments") else {
            throw DFError.database("v15_stickers 缺少 attachments 表，无法建立表情引用")
        }
        for table in newTables {
            guard try !db.tableExists(table) else {
                throw DFError.database("v15_stickers 目标表 \(table) 已存在，迁移状态不一致")
            }
        }
    }

    // MARK: - 1. 建表

    private static func createTables(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE sticker_packs (
            id          TEXT PRIMARY KEY,
            name        TEXT NOT NULL,
            source      TEXT NOT NULL,
            source_url  TEXT,
            license     TEXT,
            created_at  INTEGER NOT NULL,
            updated_at  INTEGER NOT NULL
        )
        """)

        // attachment_id 可为空：Emoji 不需要文件；图片表情必须指向真实附件
        try db.execute(sql: """
        CREATE TABLE stickers (
            id                TEXT PRIMARY KEY,
            pack_id           TEXT REFERENCES sticker_packs(id) ON DELETE SET NULL,
            kind              TEXT NOT NULL,
            name              TEXT NOT NULL,
            tags              TEXT NOT NULL DEFAULT '',
            emoji             TEXT,
            attachment_id     TEXT REFERENCES attachments(id) ON DELETE SET NULL,
            semantics         TEXT NOT NULL DEFAULT '',
            semantics_source  TEXT NOT NULL DEFAULT 'none',
            is_favorite       INTEGER NOT NULL DEFAULT 0,
            created_at        INTEGER NOT NULL,
            updated_at        INTEGER NOT NULL,
            deleted_at        INTEGER
        )
        """)

        try db.execute(sql: """
        CREATE TABLE sticker_usage (
            sticker_id TEXT NOT NULL REFERENCES stickers(id) ON DELETE CASCADE,
            used_at    INTEGER NOT NULL,
            message_id TEXT REFERENCES messages(id) ON DELETE SET NULL,
            PRIMARY KEY (sticker_id, used_at)
        )
        """)
    }

    private static func createIndexes(_ db: Database) throws {
        let statements = [
            "CREATE INDEX ix_stickers_pack ON stickers(pack_id, created_at)",
            "CREATE INDEX ix_stickers_kind ON stickers(kind, created_at)",
            "CREATE INDEX ix_stickers_favorite ON stickers(is_favorite, created_at)",
            "CREATE INDEX ix_stickers_alive ON stickers(deleted_at)",
            "CREATE INDEX ix_sticker_usage_time ON sticker_usage(used_at)"
        ]
        for statement in statements {
            try db.execute(sql: statement)
        }
    }

    // MARK: - 2. 哨兵往返

    private static func sentinelRoundTrip(_ db: Database, now: Int64) throws {
        let packID = "__v15_sentinel_pack__"
        let stickerID = "__v15_sentinel_sticker__"

        try db.execute(
            sql: """
            INSERT INTO sticker_packs (id, name, source, source_url, license, created_at, updated_at)
            VALUES (?, 'sentinel', 'builtin', NULL, NULL, ?, ?)
            """,
            arguments: [packID, now, now]
        )
        try db.execute(
            sql: """
            INSERT INTO stickers
                (id, pack_id, kind, name, tags, emoji, attachment_id, semantics, semantics_source,
                 is_favorite, created_at, updated_at, deleted_at)
            VALUES (?, ?, 'emoji', 'sentinel', '', '🙂', NULL, '', 'none', 0, ?, ?, NULL)
            """,
            arguments: [stickerID, packID, now, now]
        )
        try db.execute(
            sql: "INSERT INTO sticker_usage (sticker_id, used_at, message_id) VALUES (?, ?, NULL)",
            arguments: [stickerID, now]
        )

        let written = try Int.fetchOne(
            db,
            sql: """
            SELECT (SELECT count(*) FROM stickers WHERE id = ?) +
                   (SELECT count(*) FROM sticker_usage WHERE sticker_id = ?)
            """,
            arguments: [stickerID, stickerID]
        ) ?? 0
        guard written == 2 else {
            throw DFError.database("v15_stickers 哨兵往返失败：新表不可写")
        }

        try db.execute(sql: "DELETE FROM sticker_usage WHERE sticker_id = ?", arguments: [stickerID])
        try db.execute(sql: "DELETE FROM stickers WHERE id = ?", arguments: [stickerID])
        try db.execute(sql: "DELETE FROM sticker_packs WHERE id = ?", arguments: [packID])
    }

    // MARK: - 3. schema_meta

    private static func previousMeta(_ db: Database) throws -> [String: String] {
        var result: [String: String] = [:]
        for key in [
            SchemaMetaKey.schemaVersion,
            SchemaMetaKey.migrationBatch,
            SchemaMetaKey.migratedAt
        ] {
            if let value = try SchemaMeta.value(db, key: key) {
                result[key] = value
            }
        }
        return result
    }

    private static func writeMeta(
        _ db: Database,
        now: Int64,
        batch: String,
        previous: [String: String]
    ) throws {
        let appliedBefore = try SchemaMeta.appliedIdentifiers(db)
        let expected = try SchemaMeta.expectedPrefixIncluding(
            current: .v15_stickers,
            appliedBefore: appliedBefore
        )
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

        try SchemaMeta.write(
            db,
            key: SchemaMetaKey.schemaVersion,
            value: MigrationID.v15_stickers.rawValue,
            at: now
        )
        try SchemaMeta.write(db, key: SchemaMetaKey.appliedPhase, value: "V2-P13", at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.expectedMigrations, value: String(expected.count), at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.migratedAt, value: String(now), at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.migrationBatch, value: batch, at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.ledgerDigest, value: digest, at: now)
    }
}

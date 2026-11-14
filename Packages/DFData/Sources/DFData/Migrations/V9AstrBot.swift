import Foundation
import GRDB
import DFCore

/// `v9_astrbot` 迁移：AstrBot 迁移批次 + 原始 ID 映射 + 待处理区。
///
/// 边界（授权书 §14.2、决策 40、D-51 / W9-5、W9-6）：
/// - 只建表，**不执行任何导入**：真实导入由迁移器在用户确认后分步执行；
/// - 不写入任何批次、映射或待处理记录：迁移状态必须来自真实执行；
/// - `astrbot_id_map` 保证同一批次内同一原始 ID 只映射一次，重复导入会被库拒绝；
/// - 未识别数据一律进 `astrbot_import_pending` 并保留原始 JSON，不得静默丢弃。
enum V9AstrBot {
    /// 迁移耗时上限（秒）：只有 DDL
    static let timeLimit: TimeInterval = 30

    /// 本迁移新增的表
    static let newTables = [
        "astrbot_migration_batches",
        "astrbot_id_map",
        "astrbot_import_pending"
    ]

    /// 本迁移新增的索引
    static let newIndexes = [
        "ix_astrbot_batches_time",
        "ix_astrbot_batches_status",
        "ux_astrbot_id_map",
        "ix_astrbot_pending_batch",
        "ix_astrbot_pending_kind"
    ]

    static func migrate(_ db: Database) throws {
        let startedAt = Date()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let batch = "V2-v9_astrbot-\(now)"

        // 0. 前置断言
        try assertUpgradable(db)

        // 1. 迁移前快照
        let messageFingerprintBefore = try V3Chat.messageFingerprint(db)
        let messagesBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? 0
        let memoriesBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM memories") ?? 0
        let personaFingerprintBefore = try V4Persona.itemFingerprint(db)
        let previous = try previousMeta(db)

        // 2. 新表与索引
        try createTables(db)
        try createIndexes(db)

        // 3. 哨兵：新表可读写，随后清理
        try sentinelRoundTrip(db, now: now)

        // 4. 校验：历史数据完全不变、新表为空
        try validate(
            db,
            messageFingerprintBefore: messageFingerprintBefore,
            messagesBefore: messagesBefore,
            memoriesBefore: memoriesBefore,
            personaFingerprintBefore: personaFingerprintBefore
        )

        // 5. schema_meta
        try writeMeta(db, now: now, batch: batch, previous: previous)

        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed <= timeLimit else {
            throw DFError.database(
                String(format: "v9_astrbot 迁移耗时 %.1fs，超过 %.0f 秒上限", elapsed, timeLimit)
            )
        }
    }

    // MARK: - 0. 前置断言

    private static func assertUpgradable(_ db: Database) throws {
        guard let version = try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion) else {
            throw DFError.database("v9_astrbot 需要 schema_meta.schema_version，当前缺失")
        }
        guard version == MigrationID.v8_chat_v2.rawValue else {
            throw DFError.database(
                "v9_astrbot 只能从 \(MigrationID.v8_chat_v2.rawValue) 升级，当前为 \(version)"
            )
        }

        let quoted = newTables.map { "'\($0)'" }.joined(separator: ",")
        let existing = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN (\(quoted))"
        ) ?? 0
        guard existing == 0 else {
            throw DFError.database("v9_astrbot 新表已存在，不可重复执行")
        }
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

    // MARK: - 1. 建表与索引

    private static func createTables(_ db: Database) throws {
        // 迁移批次：一次导入一行，重试与回滚都以批次为单位
        try db.execute(sql: """
        CREATE TABLE astrbot_migration_batches (
            id            TEXT PRIMARY KEY,
            source_kind   TEXT NOT NULL DEFAULT 'astrbot',
            source_ref    TEXT NOT NULL DEFAULT '',
            source_hash   TEXT,
            is_dry_run    INTEGER NOT NULL DEFAULT 1,
            status        TEXT NOT NULL DEFAULT 'pending',
            options_json  TEXT NOT NULL DEFAULT '{}',
            counts_json   TEXT NOT NULL DEFAULT '{}',
            checkpoint_json TEXT NOT NULL DEFAULT '{}',
            started_at    INTEGER NOT NULL,
            finished_at   INTEGER,
            error         TEXT
        )
        """)

        // 原始 ID 映射：同一批次内同一实体的原始 ID 只能映射一次
        try db.execute(sql: """
        CREATE TABLE astrbot_id_map (
            id          TEXT PRIMARY KEY,
            batch_id    TEXT NOT NULL REFERENCES astrbot_migration_batches(id) ON DELETE CASCADE,
            entity_kind TEXT NOT NULL,
            source_id   TEXT NOT NULL,
            target_id   TEXT NOT NULL,
            source_hash TEXT,
            created_at  INTEGER NOT NULL
        )
        """)

        // 待处理区：未识别/冲突数据保留原始内容，等待人工决定
        try db.execute(sql: """
        CREATE TABLE astrbot_import_pending (
            id                 TEXT PRIMARY KEY,
            batch_id           TEXT NOT NULL REFERENCES astrbot_migration_batches(id) ON DELETE CASCADE,
            entity_kind        TEXT NOT NULL,
            source_id          TEXT,
            reason_code        TEXT NOT NULL,
            raw_json           TEXT NOT NULL,
            status             TEXT NOT NULL DEFAULT 'pending',
            resolved_target_id TEXT,
            created_at         INTEGER NOT NULL,
            resolved_at        INTEGER
        )
        """)
    }

    private static func createIndexes(_ db: Database) throws {
        let statements = [
            "CREATE INDEX ix_astrbot_batches_time ON astrbot_migration_batches(started_at)",
            "CREATE INDEX ix_astrbot_batches_status ON astrbot_migration_batches(status, started_at)",
            "CREATE UNIQUE INDEX ux_astrbot_id_map ON astrbot_id_map(batch_id, entity_kind, source_id)",
            "CREATE INDEX ix_astrbot_pending_batch ON astrbot_import_pending(batch_id, status)",
            "CREATE INDEX ix_astrbot_pending_kind ON astrbot_import_pending(entity_kind, status)"
        ]
        for statement in statements {
            try db.execute(sql: statement)
        }
    }

    // MARK: - 2. 哨兵

    private static func sentinelRoundTrip(_ db: Database, now: Int64) throws {
        let batchID = "__v9_sentinel_batch__"

        try db.execute(
            sql: """
            INSERT INTO astrbot_migration_batches (id, source_kind, source_ref, is_dry_run, status, started_at)
            VALUES (?, 'astrbot', 'sentinel', 1, 'succeeded', ?)
            """,
            arguments: [batchID, now]
        )
        try db.execute(
            sql: """
            INSERT INTO astrbot_id_map (id, batch_id, entity_kind, source_id, target_id, created_at)
            VALUES ('__v9_sentinel_map__', ?, 'message', 'sentinel-src', 'sentinel-dst', ?)
            """,
            arguments: [batchID, now]
        )
        try db.execute(
            sql: """
            INSERT INTO astrbot_import_pending
                (id, batch_id, entity_kind, source_id, reason_code, raw_json, created_at)
            VALUES ('__v9_sentinel_pending__', ?, 'memory', 'sentinel-src', 'unrecognized', '{}', ?)
            """,
            arguments: [batchID, now]
        )

        let written = try Int.fetchOne(
            db,
            sql: """
            SELECT (SELECT count(*) FROM astrbot_migration_batches) +
                   (SELECT count(*) FROM astrbot_id_map) +
                   (SELECT count(*) FROM astrbot_import_pending)
            """
        ) ?? 0

        try db.execute(sql: "DELETE FROM astrbot_import_pending WHERE id = '__v9_sentinel_pending__'")
        try db.execute(sql: "DELETE FROM astrbot_id_map WHERE id = '__v9_sentinel_map__'")
        try db.execute(sql: "DELETE FROM astrbot_migration_batches WHERE id = ?", arguments: [batchID])

        guard written >= 3 else {
            throw DFError.database("v9_astrbot 哨兵写入失败：新表不可写")
        }
    }

    // MARK: - 3. 校验

    private static func validate(
        _ db: Database,
        messageFingerprintBefore: String,
        messagesBefore: Int,
        memoriesBefore: Int,
        personaFingerprintBefore: String
    ) throws {
        let messageFingerprintAfter = try V3Chat.messageFingerprint(db)
        guard messageFingerprintAfter == messageFingerprintBefore else {
            throw DFError.database("v9_astrbot 改动了历史消息内容（指纹不一致）")
        }
        let messagesAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? -1
        guard messagesAfter == messagesBefore else {
            throw DFError.database("v9_astrbot 改变了消息行数：\(messagesBefore) → \(messagesAfter)")
        }
        let memoriesAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM memories") ?? -1
        guard memoriesAfter == memoriesBefore else {
            throw DFError.database("v9_astrbot 改变了记忆行数：\(memoriesBefore) → \(memoriesAfter)")
        }
        let personaFingerprintAfter = try V4Persona.itemFingerprint(db)
        guard personaFingerprintAfter == personaFingerprintBefore else {
            throw DFError.database("v9_astrbot 改动了人格条目内容（指纹不一致）")
        }

        for table in newTables {
            let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? -1
            guard count == 0 else {
                throw DFError.database("v9_astrbot 不得预置数据：\(table) 有 \(count) 行")
            }
        }

        let quick = try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "unknown"
        guard quick.lowercased() == "ok" else {
            throw DFError.database("v9_astrbot 迁移后 quick_check 失败：\(quick)")
        }
    }

    // MARK: - 4. schema_meta

    private static func writeMeta(
        _ db: Database,
        now: Int64,
        batch: String,
        previous: [String: String]
    ) throws {
        let appliedBefore = try SchemaMeta.appliedIdentifiers(db)
        let expected = try SchemaMeta.expectedPrefixIncluding(current: .v9_astrbot, appliedBefore: appliedBefore)
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

        try SchemaMeta.write(db, key: SchemaMetaKey.schemaVersion, value: MigrationID.v9_astrbot.rawValue, at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.appliedPhase, value: "V2-P8", at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.expectedMigrations, value: String(expected.count), at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.migratedAt, value: String(now), at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.migrationBatch, value: batch, at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.ledgerDigest, value: digest, at: now)
    }
}

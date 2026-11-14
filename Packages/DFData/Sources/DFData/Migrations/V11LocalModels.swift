import Foundation
import GRDB
import DFCore

/// `v11_local_models` 迁移：本地模型注册表 + 运行/上下文实测事件。
///
/// 边界（D01、D02、D58、D60、D61 / W5-1～W5-6）：
/// - 只建表与索引，不写入任何模型元数据（具体模型由用户导入或下载后登记）；
/// - 下载进度、校验和、来源、许可证、上下文实测结果都落在库里，便于"离线可用性"有据可查；
/// - 事件表只追加，用于记录加载/推理/上下文探测，不修改模型记录。
enum V11LocalModels {
    static let timeLimit: TimeInterval = 60

    static let newTables = [
        "local_models",
        "model_runtime_events"
    ]

    static let newIndexes = [
        "ux_local_models_sha",
        "ix_local_models_status",
        "ix_model_events_model",
        "ix_model_events_kind"
    ]

    static func migrate(_ db: Database) throws {
        let startedAt = Date()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let batch = "V2-v11_local_models-\(now)"

        try assertUpgradable(db)

        let messageFingerprintBefore = try V3Chat.messageFingerprint(db)
        let messagesBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? 0
        let memoriesBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM memories") ?? 0
        let personaFingerprintBefore = try V4Persona.itemFingerprint(db)
        let configsBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM model_configs") ?? 0
        let previous = try previousMeta(db)

        try createTables(db)
        try createIndexes(db)
        try sentinelRoundTrip(db, now: now)

        try validate(
            db,
            messageFingerprintBefore: messageFingerprintBefore,
            messagesBefore: messagesBefore,
            memoriesBefore: memoriesBefore,
            personaFingerprintBefore: personaFingerprintBefore,
            configsBefore: configsBefore
        )

        try writeMeta(db, now: now, batch: batch, previous: previous)

        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed <= timeLimit else {
            throw DFError.database(
                String(format: "v11_local_models 迁移耗时 %.1fs，超过 %.0f 秒上限", elapsed, timeLimit)
            )
        }
    }

    // MARK: - 0. 前置断言

    private static func assertUpgradable(_ db: Database) throws {
        guard let version = try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion) else {
            throw DFError.database("v11_local_models 需要 schema_meta.schema_version，当前缺失")
        }
        guard version == MigrationID.v10_multimodal.rawValue else {
            throw DFError.database(
                "v11_local_models 只能从 \(MigrationID.v10_multimodal.rawValue) 升级，当前为 \(version)"
            )
        }

        let quoted = newTables.map { "'\($0)'" }.joined(separator: ",")
        let existing = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN (\(quoted))"
        ) ?? 0
        guard existing == 0 else {
            throw DFError.database("v11_local_models 新表已存在，不可重复执行")
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
        try db.execute(sql: """
        CREATE TABLE local_models (
            id                TEXT PRIMARY KEY,
            name              TEXT NOT NULL,
            family            TEXT NOT NULL DEFAULT '',
            quantization      TEXT NOT NULL DEFAULT '',
            format            TEXT NOT NULL DEFAULT 'gguf',
            file_rel_path     TEXT NOT NULL DEFAULT '',
            byte_size         INTEGER NOT NULL DEFAULT 0,
            sha256            TEXT,
            source_url        TEXT,
            license           TEXT,
            version           TEXT NOT NULL DEFAULT '',
            context_length    INTEGER,
            supports_vision   INTEGER NOT NULL DEFAULT 0,
            supports_asr      INTEGER NOT NULL DEFAULT 0,
            supports_tools    INTEGER NOT NULL DEFAULT 0,
            status            TEXT NOT NULL DEFAULT 'not_downloaded',
            downloaded_bytes  INTEGER NOT NULL DEFAULT 0,
            wifi_only         INTEGER NOT NULL DEFAULT 1,
            last_verified_at  INTEGER,
            created_at        INTEGER NOT NULL,
            updated_at        INTEGER NOT NULL
        )
        """)

        try db.execute(sql: """
        CREATE TABLE model_runtime_events (
            id             TEXT PRIMARY KEY,
            model_id       TEXT REFERENCES local_models(id) ON DELETE CASCADE,
            kind           TEXT NOT NULL,
            detail         TEXT NOT NULL DEFAULT '',
            context_tokens INTEGER,
            elapsed_ms     INTEGER,
            created_at     INTEGER NOT NULL
        )
        """)
    }

    private static func createIndexes(_ db: Database) throws {
        let statements = [
            "CREATE UNIQUE INDEX ux_local_models_sha ON local_models(sha256) WHERE sha256 IS NOT NULL",
            "CREATE INDEX ix_local_models_status ON local_models(status, updated_at)",
            "CREATE INDEX ix_model_events_model ON model_runtime_events(model_id, created_at)",
            "CREATE INDEX ix_model_events_kind ON model_runtime_events(kind, created_at)"
        ]
        for statement in statements {
            try db.execute(sql: statement)
        }
    }

    // MARK: - 2. 哨兵

    private static func sentinelRoundTrip(_ db: Database, now: Int64) throws {
        let modelID = "__v11_sentinel_model__"
        let eventID = "__v11_sentinel_event__"

        try db.execute(
            sql: """
            INSERT INTO local_models (id, name, family, byte_size, status, created_at, updated_at)
            VALUES (?, 'v11 sentinel', 'test', 1, 'not_downloaded', ?, ?)
            """,
            arguments: [modelID, now, now]
        )
        try db.execute(
            sql: """
            INSERT INTO model_runtime_events (id, model_id, kind, detail, created_at)
            VALUES (?, ?, 'load', 'sentinel', ?)
            """,
            arguments: [eventID, modelID, now]
        )

        let written = try Int.fetchOne(
            db,
            sql: """
            SELECT (SELECT count(*) FROM local_models) + (SELECT count(*) FROM model_runtime_events)
            """
        ) ?? 0

        try db.execute(sql: "DELETE FROM model_runtime_events WHERE id = ?", arguments: [eventID])
        try db.execute(sql: "DELETE FROM local_models WHERE id = ?", arguments: [modelID])

        guard written >= 2 else {
            throw DFError.database("v11_local_models 哨兵写入失败：新表不可写")
        }
    }

    // MARK: - 3. 校验

    private static func validate(
        _ db: Database,
        messageFingerprintBefore: String,
        messagesBefore: Int,
        memoriesBefore: Int,
        personaFingerprintBefore: String,
        configsBefore: Int
    ) throws {
        guard try V3Chat.messageFingerprint(db) == messageFingerprintBefore else {
            throw DFError.database("v11_local_models 改动了历史消息内容（指纹不一致）")
        }
        let messagesAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? -1
        guard messagesAfter == messagesBefore else {
            throw DFError.database("v11_local_models 改变了消息行数：\(messagesBefore) → \(messagesAfter)")
        }
        let memoriesAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM memories") ?? -1
        guard memoriesAfter == memoriesBefore else {
            throw DFError.database("v11_local_models 改变了记忆行数：\(memoriesBefore) → \(memoriesAfter)")
        }
        guard try V4Persona.itemFingerprint(db) == personaFingerprintBefore else {
            throw DFError.database("v11_local_models 改动了人格条目内容（指纹不一致）")
        }
        let configsAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM model_configs") ?? -1
        guard configsAfter == configsBefore else {
            throw DFError.database("v11_local_models 改变了模型配置行数：\(configsBefore) → \(configsAfter)")
        }

        for table in newTables {
            let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? -1
            guard count == 0 else {
                throw DFError.database("v11_local_models 不得预置数据：\(table) 有 \(count) 行")
            }
        }

        let quick = try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "unknown"
        guard quick.lowercased() == "ok" else {
            throw DFError.database("v11_local_models 迁移后 quick_check 失败：\(quick)")
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
        let expected = try SchemaMeta.expectedPrefixIncluding(current: .v11_local_models, appliedBefore: appliedBefore)
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

        try SchemaMeta.write(db, key: SchemaMetaKey.schemaVersion, value: MigrationID.v11_local_models.rawValue, at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.appliedPhase, value: "V2-P9", at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.expectedMigrations, value: String(expected.count), at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.migratedAt, value: String(now), at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.migrationBatch, value: batch, at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.ledgerDigest, value: digest, at: now)
    }
}

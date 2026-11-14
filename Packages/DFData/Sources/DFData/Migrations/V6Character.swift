import Foundation
import GRDB
import DFCore

/// `v6_character` 迁移：角色形象 + 表情定义 + 当前状态 + 状态历史 + 主动消息治理列。
///
/// 边界（决策 24、52、68 / W6-8、W7-4、W7-6）：
/// - 只做 DDL 与"新列默认值"，**不修改任何历史行的既有内容**；
/// - 不预置任何角色、表情或状态：角色由用户确认后创建，表情资产缺失时降级为纯文字；
/// - `proactive_messages` 只加列，历史主动消息保持不变（`character_id` 等保持 NULL）；
/// - 反馈列默认 `none`、收藏默认 0，表示"用户尚未表态"，不得推断为喜欢或不喜欢。
enum V6Character {
    /// 迁移耗时上限（秒）：只有 DDL 与小表结构校验
    static let timeLimit: TimeInterval = 30

    /// 本迁移新增的表
    static let newTables = [
        "characters",
        "character_moods",
        "character_states",
        "character_state_history"
    ]

    /// 本迁移新增的索引
    static let newIndexes = [
        "ix_character_moods_char",
        "ux_character_moods_code",
        "ux_character_states_char",
        "ix_character_state_history_time",
        "ix_proactive_messages_feedback"
    ]

    /// `proactive_messages` 在 v5 结束时的列（仅作验收比对基线，顺序固定）
    static let legacyProactiveColumns = [
        "id", "intent_id", "planned_at", "text", "is_voice", "status",
        "suppress_reason", "notification_id", "resolved_at",
        "priority", "expires_at", "dedupe_key", "message_id", "sent_at"
    ]

    /// 本迁移追加到 `proactive_messages` 的列
    static let newProactiveColumns = [
        "character_id", "mood_code", "notify_level",
        "feedback", "feedback_at", "is_favorite",
        "trigger_kind", "trigger_ref"
    ]

    static func migrate(_ db: Database) throws {
        let startedAt = Date()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let batch = "V2-v6_character-\(now)"

        // 0. 前置断言
        try assertUpgradable(db)

        // 1. 迁移前快照
        let messageFingerprintBefore = try V3Chat.messageFingerprint(db)
        let messagesBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? 0
        let personaFingerprintBefore = try V4Persona.itemFingerprint(db)
        let proactiveRowsBefore = try proactiveRows(db)
        let columnsBefore = try proactiveColumns(db)
        let previous = try previousMeta(db)

        // 2. 主动消息加列（只改 schema，不重写历史行）
        try addProactiveColumns(db)

        // 3. 新表与索引
        try createTables(db)
        try createIndexes(db)

        // 4. 哨兵：新表可读写，随后清理
        try sentinelRoundTrip(db, now: now)

        // 5. 校验：历史行不变、新列默认值合理、角色未被预置
        try validate(
            db,
            messageFingerprintBefore: messageFingerprintBefore,
            messagesBefore: messagesBefore,
            personaFingerprintBefore: personaFingerprintBefore,
            proactiveRowsBefore: proactiveRowsBefore,
            columnsBefore: columnsBefore
        )

        // 6. schema_meta
        try writeMeta(db, now: now, batch: batch, previous: previous)

        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed <= timeLimit else {
            throw DFError.database(
                String(format: "v6_character 迁移耗时 %.1fs，超过 %.0f 秒上限", elapsed, timeLimit)
            )
        }
    }

    // MARK: - 0. 前置断言

    private static func assertUpgradable(_ db: Database) throws {
        guard let version = try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion) else {
            throw DFError.database("v6_character 需要 schema_meta.schema_version，当前缺失")
        }
        guard version == MigrationID.v5_autonomy.rawValue else {
            throw DFError.database(
                "v6_character 只能从 \(MigrationID.v5_autonomy.rawValue) 升级，当前为 \(version)"
            )
        }

        let quoted = newTables.map { "'\($0)'" }.joined(separator: ",")
        let existing = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN (\(quoted))"
        ) ?? 0
        guard existing == 0 else {
            throw DFError.database("v6_character 新表已存在，不可重复执行")
        }

        guard !(try hasColumn(db, table: "proactive_messages", column: "feedback")) else {
            throw DFError.database("proactive_messages.feedback 已存在，v6_character 不可重复执行")
        }
    }

    private static func hasColumn(_ db: Database, table: String, column: String) throws -> Bool {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        return try rows.contains { try $0.decode(String.self, forColumn: "name") == column }
    }

    // MARK: - 1. 快照

    private static func proactiveColumns(_ db: Database) throws -> [String] {
        try Row.fetchAll(db, sql: "PRAGMA table_info(proactive_messages)").map {
            try $0.decode(String.self, forColumn: "name")
        }
    }

    /// 历史主动消息逐行指纹：既有 14 列内容不得被本迁移改动
    static func proactiveRows(_ db: Database) throws -> String {
        let columns = legacyProactiveColumns.map { "quote(\($0))" }.joined(separator: " || char(31) || ")
        let lines = try String.fetchAll(
            db,
            sql: "SELECT \(columns) AS line FROM proactive_messages ORDER BY id"
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

    // MARK: - 2. 主动消息加列

    private static func addProactiveColumns(_ db: Database) throws {
        let statements = [
            "ALTER TABLE proactive_messages ADD COLUMN character_id TEXT",
            "ALTER TABLE proactive_messages ADD COLUMN mood_code TEXT",
            "ALTER TABLE proactive_messages ADD COLUMN notify_level TEXT NOT NULL DEFAULT 'full'",
            "ALTER TABLE proactive_messages ADD COLUMN feedback TEXT NOT NULL DEFAULT 'none'",
            "ALTER TABLE proactive_messages ADD COLUMN feedback_at INTEGER",
            "ALTER TABLE proactive_messages ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE proactive_messages ADD COLUMN trigger_kind TEXT",
            "ALTER TABLE proactive_messages ADD COLUMN trigger_ref TEXT"
        ]
        for statement in statements {
            try db.execute(sql: statement)
        }
    }

    // MARK: - 3. 建表与索引

    private static func createTables(_ db: Database) throws {
        // 角色：内置与自定义同一结构，资产缺失时可只保留文字形象
        try db.execute(sql: """
        CREATE TABLE characters (
            id              TEXT PRIMARY KEY,
            name            TEXT NOT NULL,
            kind            TEXT NOT NULL DEFAULT 'builtin',
            summary         TEXT NOT NULL DEFAULT '',
            avatar_rel_path TEXT,
            is_active       INTEGER NOT NULL DEFAULT 0,
            sort            INTEGER NOT NULL DEFAULT 0,
            created_at      INTEGER NOT NULL,
            updated_at      INTEGER NOT NULL
        )
        """)

        // 表情/动作定义：同一角色下 code 唯一
        try db.execute(sql: """
        CREATE TABLE character_moods (
            id              TEXT PRIMARY KEY,
            character_id    TEXT NOT NULL REFERENCES characters(id) ON DELETE CASCADE,
            code            TEXT NOT NULL,
            name            TEXT NOT NULL,
            asset_rel_path  TEXT,
            is_builtin      INTEGER NOT NULL DEFAULT 0,
            sort            INTEGER NOT NULL DEFAULT 0,
            created_at      INTEGER NOT NULL
        )
        """)

        // 当前状态：每个角色只有一行，由表情与数值共同表达
        try db.execute(sql: """
        CREATE TABLE character_states (
            id            TEXT PRIMARY KEY,
            character_id  TEXT NOT NULL REFERENCES characters(id) ON DELETE CASCADE,
            mood_code     TEXT NOT NULL DEFAULT 'neutral',
            energy        REAL NOT NULL DEFAULT 0.5,
            affinity      REAL NOT NULL DEFAULT 0.5,
            source        TEXT NOT NULL DEFAULT 'system',
            context_json  TEXT NOT NULL DEFAULT '{}',
            updated_at    INTEGER NOT NULL
        )
        """)

        // 状态变更历史：表情变化必须可追溯，不允许无记录跳变
        try db.execute(sql: """
        CREATE TABLE character_state_history (
            id                 TEXT PRIMARY KEY,
            character_id       TEXT NOT NULL REFERENCES characters(id) ON DELETE CASCADE,
            from_mood          TEXT,
            to_mood            TEXT NOT NULL,
            from_energy        REAL,
            to_energy          REAL,
            reason             TEXT NOT NULL DEFAULT '',
            trigger_message_id TEXT,
            created_at         INTEGER NOT NULL
        )
        """)
    }

    private static func createIndexes(_ db: Database) throws {
        let statements = [
            "CREATE INDEX ix_character_moods_char ON character_moods(character_id, sort)",
            "CREATE UNIQUE INDEX ux_character_moods_code ON character_moods(character_id, code)",
            "CREATE UNIQUE INDEX ux_character_states_char ON character_states(character_id)",
            "CREATE INDEX ix_character_state_history_time ON character_state_history(character_id, created_at)",
            "CREATE INDEX ix_proactive_messages_feedback ON proactive_messages(feedback, created_at)"
        ]
        for statement in statements {
            try db.execute(sql: statement)
        }
    }

    // MARK: - 4. 哨兵

    /// 用一条临时角色 + 表情 + 状态 + 历史验证新表可写，随后全部删除。
    /// 另插一条临时主动消息验证新列可写（`intent_id` 留空，不依赖其它表）。
    private static func sentinelRoundTrip(_ db: Database, now: Int64) throws {
        let characterID = "__v6_sentinel_char__"

        try db.execute(
            sql: """
            INSERT INTO characters (id, name, kind, is_active, created_at, updated_at)
            VALUES (?, 'v6 sentinel', 'sentinel', 0, ?, ?)
            """,
            arguments: [characterID, now, now]
        )
        try db.execute(
            sql: """
            INSERT INTO character_moods (id, character_id, code, name, created_at)
            VALUES ('__v6_sentinel_mood__', ?, 'sentinel', 'sentinel', ?)
            """,
            arguments: [characterID, now]
        )
        try db.execute(
            sql: """
            INSERT INTO character_states (id, character_id, mood_code, updated_at)
            VALUES ('__v6_sentinel_state__', ?, 'sentinel', ?)
            """,
            arguments: [characterID, now]
        )
        try db.execute(
            sql: """
            INSERT INTO character_state_history (id, character_id, to_mood, reason, created_at)
            VALUES ('__v6_sentinel_history__', ?, 'sentinel', 'migration', ?)
            """,
            arguments: [characterID, now]
        )
        try db.execute(
            sql: """
            INSERT INTO proactive_messages
                (id, planned_at, text, status, character_id, mood_code, notify_level, feedback, is_favorite)
            VALUES ('__v6_sentinel_proactive__', ?, 'sentinel', 'planned', ?, 'sentinel', 'hidden', 'none', 0)
            """,
            arguments: [now, characterID]
        )

        let written = try Int.fetchOne(
            db,
            sql: """
            SELECT (SELECT count(*) FROM characters) +
                   (SELECT count(*) FROM character_moods) +
                   (SELECT count(*) FROM character_states) +
                   (SELECT count(*) FROM character_state_history) +
                   (SELECT count(*) FROM proactive_messages WHERE id = '__v6_sentinel_proactive__')
            """
        ) ?? 0

        try db.execute(sql: "DELETE FROM proactive_messages WHERE id = '__v6_sentinel_proactive__'")
        try db.execute(sql: "DELETE FROM character_state_history WHERE id = '__v6_sentinel_history__'")
        try db.execute(sql: "DELETE FROM character_states WHERE id = '__v6_sentinel_state__'")
        try db.execute(sql: "DELETE FROM character_moods WHERE id = '__v6_sentinel_mood__'")
        try db.execute(sql: "DELETE FROM characters WHERE id = ?", arguments: [characterID])

        guard written >= 5 else {
            throw DFError.database("v6_character 哨兵写入失败：新表或新列不可写")
        }
    }

    // MARK: - 5. 校验

    private static func validate(
        _ db: Database,
        messageFingerprintBefore: String,
        messagesBefore: Int,
        personaFingerprintBefore: String,
        proactiveRowsBefore: String,
        columnsBefore: [String]
    ) throws {
        let messageFingerprintAfter = try V3Chat.messageFingerprint(db)
        guard messageFingerprintAfter == messageFingerprintBefore else {
            throw DFError.database("v6_character 改动了历史消息内容（指纹不一致）")
        }
        let messagesAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? -1
        guard messagesAfter == messagesBefore else {
            throw DFError.database("v6_character 改变了消息行数：\(messagesBefore) → \(messagesAfter)")
        }
        let personaFingerprintAfter = try V4Persona.itemFingerprint(db)
        guard personaFingerprintAfter == personaFingerprintBefore else {
            throw DFError.database("v6_character 改动了人格条目内容（指纹不一致）")
        }

        // 历史主动消息内容不变
        let proactiveRowsAfter = try proactiveRows(db)
        guard proactiveRowsAfter == proactiveRowsBefore else {
            throw DFError.database("v6_character 改动了历史主动消息内容（指纹不一致）")
        }

        // 列结构：既有列顺序不变，追加 8 列
        let columnsAfter = try proactiveColumns(db)
        let expectedCount = legacyProactiveColumns.count + newProactiveColumns.count
        guard columnsAfter.count == expectedCount else {
            throw DFError.database("v6_character 后 proactive_messages 列数应为 \(expectedCount)，实际 \(columnsAfter.count)")
        }
        guard Array(columnsAfter.prefix(legacyProactiveColumns.count)) == columnsBefore,
              Array(columnsAfter.prefix(legacyProactiveColumns.count)) == legacyProactiveColumns else {
            throw DFError.database("v6_character 改变了 proactive_messages 既有列的顺序或名称")
        }
        guard Array(columnsAfter.suffix(newProactiveColumns.count)) == newProactiveColumns else {
            throw DFError.database("v6_character 追加的主动消息列与预期不一致：\(columnsAfter)")
        }

        // 历史行不得被推断成"喜欢"或"已读/已渲染角色"
        let inferred = try Int.fetchOne(
            db,
            sql: """
            SELECT count(*) FROM proactive_messages
             WHERE character_id IS NOT NULL OR mood_code IS NOT NULL
                OR feedback_at IS NOT NULL OR is_favorite <> 0 OR trigger_kind IS NOT NULL
            """
        ) ?? -1
        guard inferred == 0 else {
            throw DFError.database("v6_character 不得为历史主动消息回填角色或反馈：\(inferred) 行")
        }

        // 角色不得凭空预置
        for table in newTables {
            let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? -1
            guard count == 0 else {
                throw DFError.database("v6_character 不得预置数据：\(table) 有 \(count) 行")
            }
        }

        let quick = try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "unknown"
        guard quick.lowercased() == "ok" else {
            throw DFError.database("v6_character 迁移后 quick_check 失败：\(quick)")
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
        let expected = try SchemaMeta.expectedPrefixIncluding(current: .v6_character, appliedBefore: appliedBefore)
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

        try SchemaMeta.write(db, key: SchemaMetaKey.schemaVersion, value: MigrationID.v6_character.rawValue, at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.appliedPhase, value: "V2-P5", at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.expectedMigrations, value: String(expected.count), at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.migratedAt, value: String(now), at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.migrationBatch, value: batch, at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.ledgerDigest, value: digest, at: now)
    }
}

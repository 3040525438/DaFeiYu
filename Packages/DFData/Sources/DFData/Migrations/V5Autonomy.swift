import Foundation
import GRDB
import DFCore

/// `v5_autonomy` 迁移：话题 / 意图 / 自主任务 / 自主运行记录 / 自主开关 + 会话置顶与未读列。
///
/// 边界（决策 31、46、49、55、68 / D62）：
/// - 只做 DDL 与"新列默认值"，**不修改任何历史行的既有内容**；
/// - 不写入任何话题、意图、任务、运行记录：主动联系必须先有真实素材与用户授权；
/// - `autonomy_controls` 迁移后必须为空：**未开启即不主动**，默认值由设置模块在用户确认后写入；
/// - 话题归属关系（一个意图恰好一个消息组）由部分唯一索引在库层强制，而不是只靠应用层自觉。
enum V5Autonomy {
    /// 迁移耗时上限（秒）：只有 DDL 与小表结构校验
    static let timeLimit: TimeInterval = 30

    /// 本迁移新增的表
    static let newTables = [
        "conversation_topics",
        "conversation_intents",
        "autonomy_tasks",
        "autonomy_runs",
        "autonomy_controls"
    ]

    /// 本迁移新增的索引
    static let newIndexes = [
        "ix_conversation_topics_conv",
        "ix_conversation_topics_status",
        "ux_conversation_intents_group",
        "ix_conversation_intents_status",
        "ix_conversation_intents_topic",
        "ux_autonomy_tasks_dedupe",
        "ix_autonomy_tasks_due",
        "ix_autonomy_tasks_kind",
        "ix_autonomy_runs_time",
        "ix_autonomy_runs_task",
        "ux_autonomy_controls_kind"
    ]

    /// `conversations` 在 v4 结束时的列（仅作验收比对基线，顺序固定）
    static let legacyConversationColumns = [
        "id", "title", "kind", "created_at", "updated_at", "archived_at"
    ]

    /// 本迁移追加到 `conversations` 的列（只加列，不回填历史语义）
    static let newConversationColumns = [
        "pinned_at", "sort_index", "unread_count", "last_read_at"
    ]

    static func migrate(_ db: Database) throws {
        let startedAt = Date()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let batch = "V2-v5_autonomy-\(now)"

        // 0. 前置断言
        try assertUpgradable(db)

        // 1. 迁移前快照（校验历史内容不被动过）
        let conversationIDsBefore = try String.fetchAll(db, sql: "SELECT id FROM conversations ORDER BY id")
        let messageFingerprintBefore = try V3Chat.messageFingerprint(db)
        let messagesBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? 0
        let memoriesBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM memories") ?? 0
        let personaFingerprintBefore = try V4Persona.itemFingerprint(db)
        let columnsBefore = try conversationColumns(db)
        let previous = try previousMeta(db)

        // 2. 会话加列（只改 schema，不重写历史行）
        try addConversationColumns(db)

        // 3. 新表与索引
        try createTables(db)
        try createIndexes(db)

        // 4. 哨兵：新表可读写，随后清理
        try sentinelRoundTrip(db, now: now)

        // 5. 校验：历史行不变、新列默认值合理、自主开关未被自动开启
        try validate(
            db,
            conversationIDsBefore: conversationIDsBefore,
            messageFingerprintBefore: messageFingerprintBefore,
            messagesBefore: messagesBefore,
            memoriesBefore: memoriesBefore,
            personaFingerprintBefore: personaFingerprintBefore,
            columnsBefore: columnsBefore
        )

        // 6. schema_meta
        try writeMeta(db, now: now, batch: batch, previous: previous)

        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed <= timeLimit else {
            throw DFError.database(
                String(format: "v5_autonomy 迁移耗时 %.1fs，超过 %.0f 秒上限", elapsed, timeLimit)
            )
        }
    }

    // MARK: - 0. 前置断言

    private static func assertUpgradable(_ db: Database) throws {
        guard let version = try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion) else {
            throw DFError.database("v5_autonomy 需要 schema_meta.schema_version，当前缺失")
        }
        guard version == MigrationID.v4_persona.rawValue else {
            throw DFError.database(
                "v5_autonomy 只能从 \(MigrationID.v4_persona.rawValue) 升级，当前为 \(version)"
            )
        }

        let quoted = newTables.map { "'\($0)'" }.joined(separator: ",")
        let existing = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN (\(quoted))"
        ) ?? 0
        guard existing == 0 else {
            throw DFError.database("v5_autonomy 新表已存在，不可重复执行")
        }

        guard !(try hasColumn(db, table: "conversations", column: "unread_count")) else {
            throw DFError.database("conversations.unread_count 已存在，v5_autonomy 不可重复执行")
        }
    }

    private static func hasColumn(_ db: Database, table: String, column: String) throws -> Bool {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        return try rows.contains { try $0.decode(String.self, forColumn: "name") == column }
    }

    // MARK: - 1. 快照

    private static func conversationColumns(_ db: Database) throws -> [String] {
        try Row.fetchAll(db, sql: "PRAGMA table_info(conversations)").map {
            try $0.decode(String.self, forColumn: "name")
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

    // MARK: - 2. 会话加列

    /// 只加列：历史会话的置顶与已读时间为 NULL、未读与排序为常量默认值，
    /// 不据此推断"用户读过"或"未读过"任何历史消息。
    private static func addConversationColumns(_ db: Database) throws {
        let statements = [
            "ALTER TABLE conversations ADD COLUMN pinned_at INTEGER",
            "ALTER TABLE conversations ADD COLUMN sort_index INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE conversations ADD COLUMN unread_count INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE conversations ADD COLUMN last_read_at INTEGER"
        ]
        for statement in statements {
            try db.execute(sql: statement)
        }
    }

    // MARK: - 3. 建表与索引

    private static func createTables(_ db: Database) throws {
        // 聊天话题：状态机挂在"话题 × 会话"上，可同时存在多个未完成话题
        try db.execute(sql: """
        CREATE TABLE conversation_topics (
            id                  TEXT PRIMARY KEY,
            conversation_id     TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            title               TEXT NOT NULL,
            summary             TEXT NOT NULL DEFAULT '',
            status              TEXT NOT NULL DEFAULT 'open',
            priority            INTEGER NOT NULL DEFAULT 2,
            has_pending_followup INTEGER NOT NULL DEFAULT 0,
            last_intent_at      INTEGER,
            opened_at           INTEGER NOT NULL,
            last_touched_at     INTEGER NOT NULL,
            closed_reason       TEXT,
            evidence_json       TEXT NOT NULL DEFAULT '[]',
            created_at          INTEGER NOT NULL,
            updated_at          INTEGER NOT NULL
        )
        """)

        // 意图：一次"我想说这件事"。一个意图对应恰好一个消息组（C18）
        try db.execute(sql: """
        CREATE TABLE conversation_intents (
            id              TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            topic_id        TEXT REFERENCES conversation_topics(id) ON DELETE SET NULL,
            group_id        TEXT REFERENCES message_groups(id) ON DELETE SET NULL,
            kind            TEXT NOT NULL DEFAULT 'followup',
            status          TEXT NOT NULL DEFAULT 'planned',
            trigger         TEXT NOT NULL DEFAULT 'user',
            reason          TEXT NOT NULL DEFAULT '',
            evidence_json   TEXT NOT NULL DEFAULT '[]',
            confidence      REAL NOT NULL DEFAULT 0.5,
            priority        INTEGER NOT NULL DEFAULT 3,
            planned_at      INTEGER NOT NULL,
            expires_at      INTEGER,
            suppress_reason TEXT,
            decided_by      TEXT,
            created_at      INTEGER NOT NULL,
            resolved_at     INTEGER
        )
        """)

        // 自主任务队列：dedupe_key 唯一，保证同一话题同一类型在时间窗内只排一次
        try db.execute(sql: """
        CREATE TABLE autonomy_tasks (
            id              TEXT PRIMARY KEY,
            kind            TEXT NOT NULL,
            conversation_id TEXT REFERENCES conversations(id) ON DELETE CASCADE,
            topic_id        TEXT REFERENCES conversation_topics(id) ON DELETE SET NULL,
            dedupe_key      TEXT NOT NULL,
            status          TEXT NOT NULL DEFAULT 'pending',
            priority        INTEGER NOT NULL DEFAULT 3,
            scheduled_at    INTEGER NOT NULL,
            expires_at      INTEGER,
            attempts        INTEGER NOT NULL DEFAULT 0,
            max_attempts    INTEGER NOT NULL DEFAULT 3,
            last_attempt_at INTEGER,
            payload_json    TEXT NOT NULL DEFAULT '{}',
            result_json     TEXT,
            error           TEXT,
            created_at      INTEGER NOT NULL,
            updated_at      INTEGER NOT NULL
        )
        """)

        // 执行记录：每次思考/执行/跳过都必须留痕，供"查看触发原因"与补算排查
        try db.execute(sql: """
        CREATE TABLE autonomy_runs (
            id              TEXT PRIMARY KEY,
            task_id         TEXT REFERENCES autonomy_tasks(id) ON DELETE SET NULL,
            kind            TEXT NOT NULL,
            trigger         TEXT NOT NULL DEFAULT 'foreground',
            status          TEXT NOT NULL DEFAULT 'running',
            decision        TEXT,
            block_reason    TEXT,
            model_config_id TEXT,
            started_at      INTEGER NOT NULL,
            finished_at     INTEGER,
            duration_ms     INTEGER,
            detail_json     TEXT NOT NULL DEFAULT '{}',
            error           TEXT
        )
        """)

        // 自主度分项开关：默认关闭，只有用户显式开启后才允许主动行为
        try db.execute(sql: """
        CREATE TABLE autonomy_controls (
            id           TEXT PRIMARY KEY,
            item_kind    TEXT NOT NULL,
            level        TEXT NOT NULL DEFAULT 'off',
            enabled      INTEGER NOT NULL DEFAULT 0,
            paused_until INTEGER,
            updated_by   TEXT NOT NULL DEFAULT 'user',
            updated_at   INTEGER NOT NULL
        )
        """)
    }

    private static func createIndexes(_ db: Database) throws {
        let statements = [
            "CREATE INDEX ix_conversation_topics_conv ON conversation_topics(conversation_id, status, last_touched_at)",
            "CREATE INDEX ix_conversation_topics_status ON conversation_topics(status, priority, last_touched_at)",
            // 一个意图最多绑定一个消息组；历史空值不参与唯一性
            "CREATE UNIQUE INDEX ux_conversation_intents_group ON conversation_intents(group_id) WHERE group_id IS NOT NULL",
            "CREATE INDEX ix_conversation_intents_status ON conversation_intents(status, planned_at)",
            "CREATE INDEX ix_conversation_intents_topic ON conversation_intents(topic_id, created_at)",
            "CREATE UNIQUE INDEX ux_autonomy_tasks_dedupe ON autonomy_tasks(dedupe_key)",
            "CREATE INDEX ix_autonomy_tasks_due ON autonomy_tasks(status, scheduled_at)",
            "CREATE INDEX ix_autonomy_tasks_kind ON autonomy_tasks(kind, status)",
            "CREATE INDEX ix_autonomy_runs_time ON autonomy_runs(started_at)",
            "CREATE INDEX ix_autonomy_runs_task ON autonomy_runs(task_id)",
            "CREATE UNIQUE INDEX ux_autonomy_controls_kind ON autonomy_controls(item_kind)"
        ]
        for statement in statements {
            try db.execute(sql: statement)
        }
    }

    // MARK: - 4. 哨兵

    /// 用一条临时会话 + 五张新表各一行验证可写，随后全部删除；不依赖库中已有数据。
    private static func sentinelRoundTrip(_ db: Database, now: Int64) throws {
        let conversationID = "__v5_sentinel_conv__"

        try db.execute(
            sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at, pinned_at, sort_index, unread_count, last_read_at)
            VALUES (?, 'v5 sentinel', 'sentinel', ?, ?, ?, 0, 0, NULL)
            """,
            arguments: [conversationID, now, now, now]
        )
        try db.execute(
            sql: """
            INSERT INTO conversation_topics
                (id, conversation_id, title, status, opened_at, last_touched_at, created_at, updated_at)
            VALUES ('__v5_sentinel_topic__', ?, 'sentinel', 'open', ?, ?, ?, ?)
            """,
            arguments: [conversationID, now, now, now, now]
        )
        try db.execute(
            sql: """
            INSERT INTO conversation_intents
                (id, conversation_id, topic_id, kind, status, planned_at, created_at)
            VALUES ('__v5_sentinel_intent__', ?, '__v5_sentinel_topic__', 'followup', 'planned', ?, ?)
            """,
            arguments: [conversationID, now, now]
        )
        try db.execute(
            sql: """
            INSERT INTO autonomy_tasks
                (id, kind, conversation_id, topic_id, dedupe_key, scheduled_at, created_at, updated_at)
            VALUES ('__v5_sentinel_task__', 'sentinel', ?, '__v5_sentinel_topic__', '__v5_sentinel_dedupe__', ?, ?, ?)
            """,
            arguments: [conversationID, now, now, now]
        )
        try db.execute(
            sql: """
            INSERT INTO autonomy_runs (id, task_id, kind, trigger, status, started_at)
            VALUES ('__v5_sentinel_run__', '__v5_sentinel_task__', 'sentinel', 'manual', 'succeeded', ?)
            """,
            arguments: [now]
        )
        try db.execute(
            sql: """
            INSERT INTO autonomy_controls (id, item_kind, level, enabled, updated_at)
            VALUES ('__v5_sentinel_control__', '__v5_sentinel_kind__', 'off', 0, ?)
            """,
            arguments: [now]
        )

        let written = try Int.fetchOne(
            db,
            sql: """
            SELECT (SELECT count(*) FROM conversation_topics) +
                   (SELECT count(*) FROM conversation_intents) +
                   (SELECT count(*) FROM autonomy_tasks) +
                   (SELECT count(*) FROM autonomy_runs) +
                   (SELECT count(*) FROM autonomy_controls)
            """
        ) ?? 0

        try db.execute(sql: "DELETE FROM autonomy_runs WHERE id = '__v5_sentinel_run__'")
        try db.execute(sql: "DELETE FROM autonomy_controls WHERE id = '__v5_sentinel_control__'")
        try db.execute(sql: "DELETE FROM autonomy_tasks WHERE id = '__v5_sentinel_task__'")
        try db.execute(sql: "DELETE FROM conversation_intents WHERE id = '__v5_sentinel_intent__'")
        try db.execute(sql: "DELETE FROM conversation_topics WHERE id = '__v5_sentinel_topic__'")
        try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [conversationID])

        guard written >= 5 else {
            throw DFError.database("v5_autonomy 哨兵写入失败：新表不可写")
        }
    }

    // MARK: - 5. 校验

    private static func validate(
        _ db: Database,
        conversationIDsBefore: [String],
        messageFingerprintBefore: String,
        messagesBefore: Int,
        memoriesBefore: Int,
        personaFingerprintBefore: String,
        columnsBefore: [String]
    ) throws {
        // 会话行集合不得变化
        let conversationIDsAfter = try String.fetchAll(db, sql: "SELECT id FROM conversations ORDER BY id")
        guard conversationIDsAfter == conversationIDsBefore else {
            throw DFError.database("v5_autonomy 改变了会话行集合")
        }

        // 消息与人格条目逐字不变
        let messageFingerprintAfter = try V3Chat.messageFingerprint(db)
        guard messageFingerprintAfter == messageFingerprintBefore else {
            throw DFError.database("v5_autonomy 改动了历史消息内容（指纹不一致）")
        }
        let messagesAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? -1
        guard messagesAfter == messagesBefore else {
            throw DFError.database("v5_autonomy 改变了消息行数：\(messagesBefore) → \(messagesAfter)")
        }
        let personaFingerprintAfter = try V4Persona.itemFingerprint(db)
        guard personaFingerprintAfter == personaFingerprintBefore else {
            throw DFError.database("v5_autonomy 改动了人格条目内容（指纹不一致）")
        }
        let memoriesAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM memories") ?? -1
        guard memoriesAfter == memoriesBefore else {
            throw DFError.database("v5_autonomy 改变了记忆行数：\(memoriesBefore) → \(memoriesAfter)")
        }

        // 会话列：既有列顺序不变，追加 4 列
        let columnsAfter = try conversationColumns(db)
        guard columnsAfter.count == legacyConversationColumns.count + newConversationColumns.count else {
            throw DFError.database(
                "v5_autonomy 后 conversations 列数应为 \(legacyConversationColumns.count + newConversationColumns.count)，实际 \(columnsAfter.count)"
            )
        }
        guard Array(columnsAfter.prefix(legacyConversationColumns.count)) == columnsBefore,
              Array(columnsAfter.prefix(legacyConversationColumns.count)) == legacyConversationColumns else {
            throw DFError.database("v5_autonomy 改变了 conversations 既有列的顺序或名称")
        }
        guard Array(columnsAfter.suffix(newConversationColumns.count)) == newConversationColumns else {
            throw DFError.database("v5_autonomy 追加的会话列与预期不一致：\(columnsAfter)")
        }

        // 历史会话不得被推断成"已置顶/已读"
        let pinned = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM conversations WHERE pinned_at IS NOT NULL OR last_read_at IS NOT NULL"
        ) ?? -1
        guard pinned == 0 else {
            throw DFError.database("v5_autonomy 不得为历史会话回填置顶或已读时间：\(pinned) 行")
        }
        let unread = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM conversations WHERE unread_count <> 0 OR sort_index <> 0"
        ) ?? -1
        guard unread == 0 else {
            throw DFError.database("v5_autonomy 不得为历史会话回填未读数或排序：\(unread) 行")
        }

        // 自主相关表必须为空：未开启即不主动
        for table in newTables {
            let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? -1
            guard count == 0 else {
                throw DFError.database("v5_autonomy 不得预置数据：\(table) 有 \(count) 行")
            }
        }

        let quick = try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "unknown"
        guard quick.lowercased() == "ok" else {
            throw DFError.database("v5_autonomy 迁移后 quick_check 失败：\(quick)")
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
        let expected = try SchemaMeta.expectedPrefixIncluding(current: .v5_autonomy, appliedBefore: appliedBefore)
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

        try SchemaMeta.write(db, key: SchemaMetaKey.schemaVersion, value: MigrationID.v5_autonomy.rawValue, at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.appliedPhase, value: "V2-P4", at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.expectedMigrations, value: String(expected.count), at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.migratedAt, value: String(now), at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.migrationBatch, value: batch, at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.ledgerDigest, value: digest, at: now)
    }
}

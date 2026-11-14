import Foundation
import GRDB
import DFCore

/// `v8_chat_v2` 迁移：消息编辑留痕 / 撤回 / 收藏 + 日记与版本 + 聊天与日记全文索引。
///
/// 边界（决策 12、14、19、20、28、56 / W2-3、W2-5、W6-7、W8-7）：
/// - 只做 DDL 与"新列默认值"，**不修改任何历史消息内容**；
/// - 编辑必须留痕：原文进入 `message_edits`，`messages.text` 才是最新值；
/// - 撤回不删除原文：只写 `revoked_at`，正文保留供"原文可查"；
/// - 日记一天一篇（软删后允许重建），每次改动全量快照进 `diary_entry_versions`；
/// - FTS 只存应用层生成的中文 bigram，不做分词假设，不挂 external content。
enum V8ChatV2 {
    /// 迁移耗时上限（秒）：含两张 FTS5 虚表
    static let timeLimit: TimeInterval = 60

    /// 本迁移新增的表
    static let newTables = [
        "message_edits",
        "diary_entries",
        "diary_entry_versions",
        "message_fts",
        "diary_fts"
    ]

    /// 本迁移新增的索引
    static let newIndexes = [
        "ix_message_edits_message",
        "ux_message_edits_version",
        "ux_diary_entries_date",
        "ix_diary_entries_updated",
        "ux_diary_versions",
        "ix_messages_favorite",
        "ix_messages_revoked"
    ]

    /// `messages` 在 v7 结束时的列（仅作验收比对基线，顺序固定）
    static let legacyMessageColumns = [
        "id", "client_uuid", "conversation_id", "role", "kind", "text", "status",
        "origin", "reply_to_id", "created_at", "sent_at", "model_config_id",
        "emotion_state_id", "deleted_at", "group_id", "seq_in_group"
    ]

    /// 本迁移追加到 `messages` 的列
    static let newMessageColumns = [
        "edited_at", "edit_count", "revoked_at", "revoke_reason", "is_favorite", "favorited_at"
    ]

    static func migrate(_ db: Database) throws {
        let startedAt = Date()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let batch = "V2-v8_chat_v2-\(now)"

        // 0. 前置断言
        try assertUpgradable(db)

        // 1. 迁移前快照
        let messageFingerprintBefore = try V3Chat.messageFingerprint(db)
        let messagesBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? 0
        let personaFingerprintBefore = try V4Persona.itemFingerprint(db)
        let columnsBefore = try messageColumns(db)
        let memoryObjectsBefore = try memoryObjects(db)
        let previous = try previousMeta(db)

        // 2. 消息加列（只改 schema，不重写历史行）
        try addMessageColumns(db)

        // 3. 新表、FTS 与索引
        try createTables(db)
        try createFullTextSearch(db)
        try createIndexes(db)

        // 4. 哨兵：新表与 FTS 可读写，随后清理
        try sentinelRoundTrip(db, now: now)

        // 5. 校验
        try validate(
            db,
            messageFingerprintBefore: messageFingerprintBefore,
            messagesBefore: messagesBefore,
            personaFingerprintBefore: personaFingerprintBefore,
            columnsBefore: columnsBefore,
            memoryObjectsBefore: memoryObjectsBefore
        )

        // 6. schema_meta
        try writeMeta(db, now: now, batch: batch, previous: previous)

        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed <= timeLimit else {
            throw DFError.database(
                String(format: "v8_chat_v2 迁移耗时 %.1fs，超过 %.0f 秒上限", elapsed, timeLimit)
            )
        }
    }

    // MARK: - 0. 前置断言

    private static func assertUpgradable(_ db: Database) throws {
        guard let version = try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion) else {
            throw DFError.database("v8_chat_v2 需要 schema_meta.schema_version，当前缺失")
        }
        guard version == MigrationID.v7_meta_backup.rawValue else {
            throw DFError.database(
                "v8_chat_v2 只能从 \(MigrationID.v7_meta_backup.rawValue) 升级，当前为 \(version)"
            )
        }

        let quoted = newTables.map { "'\($0)'" }.joined(separator: ",")
        let existing = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN (\(quoted))"
        ) ?? 0
        guard existing == 0 else {
            throw DFError.database("v8_chat_v2 新表已存在，不可重复执行")
        }

        guard !(try hasColumn(db, table: "messages", column: "is_favorite")) else {
            throw DFError.database("messages.is_favorite 已存在，v8_chat_v2 不可重复执行")
        }
    }

    private static func hasColumn(_ db: Database, table: String, column: String) throws -> Bool {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        return try rows.contains { try $0.decode(String.self, forColumn: "name") == column }
    }

    // MARK: - 1. 快照

    private static func messageColumns(_ db: Database) throws -> [String] {
        try Row.fetchAll(db, sql: "PRAGMA table_info(messages)").map {
            try $0.decode(String.self, forColumn: "name")
        }
    }

    private static func memoryObjects(_ db: Database) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
            SELECT name FROM sqlite_master
            WHERE name IN ('memory_fts','v_memory_user','v_memory_shared','v_memory_self','v_memory_stats')
            ORDER BY name
            """
        )
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

    // MARK: - 2. 消息加列

    private static func addMessageColumns(_ db: Database) throws {
        let statements = [
            "ALTER TABLE messages ADD COLUMN edited_at INTEGER",
            "ALTER TABLE messages ADD COLUMN edit_count INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE messages ADD COLUMN revoked_at INTEGER",
            "ALTER TABLE messages ADD COLUMN revoke_reason TEXT",
            "ALTER TABLE messages ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE messages ADD COLUMN favorited_at INTEGER"
        ]
        for statement in statements {
            try db.execute(sql: statement)
        }
    }

    // MARK: - 3. 建表与索引

    private static func createTables(_ db: Database) throws {
        // 编辑留痕：每次编辑一行，保留改前与改后全文
        try db.execute(sql: """
        CREATE TABLE message_edits (
            id          TEXT PRIMARY KEY,
            message_id  TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
            version     INTEGER NOT NULL,
            before_text TEXT NOT NULL,
            after_text  TEXT NOT NULL,
            edited_by   TEXT NOT NULL DEFAULT 'user',
            created_at  INTEGER NOT NULL
        )
        """)

        // 每日日记：一天一篇（软删后可重建）
        try db.execute(sql: """
        CREATE TABLE diary_entries (
            id             TEXT PRIMARY KEY,
            entry_date     TEXT NOT NULL,
            title          TEXT NOT NULL DEFAULT '',
            content        TEXT NOT NULL,
            mood_code      TEXT,
            source         TEXT NOT NULL DEFAULT 'manual',
            generated_by   TEXT,
            is_user_edited INTEGER NOT NULL DEFAULT 0,
            memory_id      TEXT REFERENCES memories(id) ON DELETE SET NULL,
            created_at     INTEGER NOT NULL,
            updated_at     INTEGER NOT NULL,
            deleted_at     INTEGER
        )
        """)

        // 日记版本：双方编辑都必须留全量快照
        try db.execute(sql: """
        CREATE TABLE diary_entry_versions (
            id            TEXT PRIMARY KEY,
            diary_id      TEXT NOT NULL REFERENCES diary_entries(id) ON DELETE CASCADE,
            version       INTEGER NOT NULL,
            title         TEXT NOT NULL DEFAULT '',
            content       TEXT NOT NULL,
            change_reason TEXT NOT NULL DEFAULT '',
            changed_by    TEXT NOT NULL,
            created_at    INTEGER NOT NULL
        )
        """)
    }

    private static func createFullTextSearch(_ db: Database) throws {
        // 不挂 external content：中文 bigram 由应用层生成（与 memory_fts 口径一致）
        try db.execute(sql: """
        CREATE VIRTUAL TABLE message_fts USING fts5(
            message_id UNINDEXED,
            conversation_id UNINDEXED,
            text_bigram,
            tokenize = 'unicode61'
        )
        """)
        try db.execute(sql: """
        CREATE VIRTUAL TABLE diary_fts USING fts5(
            diary_id UNINDEXED,
            text_bigram,
            tokenize = 'unicode61'
        )
        """)
    }

    private static func createIndexes(_ db: Database) throws {
        let statements = [
            "CREATE INDEX ix_message_edits_message ON message_edits(message_id, created_at)",
            "CREATE UNIQUE INDEX ux_message_edits_version ON message_edits(message_id, version)",
            "CREATE UNIQUE INDEX ux_diary_entries_date ON diary_entries(entry_date) WHERE deleted_at IS NULL",
            "CREATE INDEX ix_diary_entries_updated ON diary_entries(updated_at)",
            "CREATE UNIQUE INDEX ux_diary_versions ON diary_entry_versions(diary_id, version)",
            "CREATE INDEX ix_messages_favorite ON messages(is_favorite, created_at)",
            "CREATE INDEX ix_messages_revoked ON messages(revoked_at)"
        ]
        for statement in statements {
            try db.execute(sql: statement)
        }
    }

    // MARK: - 4. 哨兵

    private static func sentinelRoundTrip(_ db: Database, now: Int64) throws {
        let conversationID = "__v8_sentinel_conv__"
        let messageID = "__v8_sentinel_msg__"
        let diaryID = "__v8_sentinel_diary__"

        try db.execute(
            sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES (?, 'v8 sentinel', 'sentinel', ?, ?)
            """,
            arguments: [conversationID, now, now]
        )
        try db.execute(
            sql: """
            INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
            VALUES (?, '__v8_sentinel_uuid__', ?, 'assistant', 'text', 'sentinel', 'sent', 'model', ?)
            """,
            arguments: [messageID, conversationID, now]
        )
        try db.execute(
            sql: """
            INSERT INTO message_edits (id, message_id, version, before_text, after_text, created_at)
            VALUES ('__v8_sentinel_edit__', ?, 1, 'before', 'after', ?)
            """,
            arguments: [messageID, now]
        )
        try db.execute(
            sql: """
            INSERT INTO diary_entries (id, entry_date, content, created_at, updated_at)
            VALUES (?, '1970-01-01', 'sentinel', ?, ?)
            """,
            arguments: [diaryID, now, now]
        )
        try db.execute(
            sql: """
            INSERT INTO diary_entry_versions (id, diary_id, version, content, changed_by, created_at)
            VALUES ('__v8_sentinel_diary_ver__', ?, 1, 'sentinel', 'migration', ?)
            """,
            arguments: [diaryID, now]
        )
        try db.execute(
            sql: "INSERT INTO message_fts (message_id, conversation_id, text_bigram) VALUES (?, ?, 'sentinel')",
            arguments: [messageID, conversationID]
        )
        try db.execute(
            sql: "INSERT INTO diary_fts (diary_id, text_bigram) VALUES (?, 'sentinel')",
            arguments: [diaryID]
        )

        let written = try Int.fetchOne(
            db,
            sql: """
            SELECT (SELECT count(*) FROM message_edits) +
                   (SELECT count(*) FROM diary_entries) +
                   (SELECT count(*) FROM diary_entry_versions) +
                   (SELECT count(*) FROM message_fts) +
                   (SELECT count(*) FROM diary_fts)
            """
        ) ?? 0

        try db.execute(sql: "DELETE FROM diary_fts WHERE diary_id = ?", arguments: [diaryID])
        try db.execute(sql: "DELETE FROM message_fts WHERE message_id = ?", arguments: [messageID])
        try db.execute(sql: "DELETE FROM diary_entry_versions WHERE id = '__v8_sentinel_diary_ver__'")
        try db.execute(sql: "DELETE FROM diary_entries WHERE id = ?", arguments: [diaryID])
        try db.execute(sql: "DELETE FROM message_edits WHERE id = '__v8_sentinel_edit__'")
        try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [messageID])
        try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [conversationID])

        guard written >= 5 else {
            throw DFError.database("v8_chat_v2 哨兵写入失败：新表或 FTS 不可写")
        }
    }

    // MARK: - 5. 校验

    private static func validate(
        _ db: Database,
        messageFingerprintBefore: String,
        messagesBefore: Int,
        personaFingerprintBefore: String,
        columnsBefore: [String],
        memoryObjectsBefore: [String]
    ) throws {
        let messageFingerprintAfter = try V3Chat.messageFingerprint(db)
        guard messageFingerprintAfter == messageFingerprintBefore else {
            throw DFError.database("v8_chat_v2 改动了历史消息内容（指纹不一致）")
        }
        let messagesAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? -1
        guard messagesAfter == messagesBefore else {
            throw DFError.database("v8_chat_v2 改变了消息行数：\(messagesBefore) → \(messagesAfter)")
        }
        let personaFingerprintAfter = try V4Persona.itemFingerprint(db)
        guard personaFingerprintAfter == personaFingerprintBefore else {
            throw DFError.database("v8_chat_v2 改动了人格条目内容（指纹不一致）")
        }

        let columnsAfter = try messageColumns(db)
        let expectedCount = legacyMessageColumns.count + newMessageColumns.count
        guard columnsAfter.count == expectedCount else {
            throw DFError.database("v8_chat_v2 后 messages 列数应为 \(expectedCount)，实际 \(columnsAfter.count)")
        }
        guard Array(columnsAfter.prefix(legacyMessageColumns.count)) == columnsBefore,
              Array(columnsAfter.prefix(legacyMessageColumns.count)) == legacyMessageColumns else {
            throw DFError.database("v8_chat_v2 改变了 messages 既有列的顺序或名称")
        }
        guard Array(columnsAfter.suffix(newMessageColumns.count)) == newMessageColumns else {
            throw DFError.database("v8_chat_v2 追加的消息列与预期不一致：\(columnsAfter)")
        }

        // 历史消息不得被推断成已编辑/已撤回/已收藏
        let inferred = try Int.fetchOne(
            db,
            sql: """
            SELECT count(*) FROM messages
             WHERE edited_at IS NOT NULL OR edit_count <> 0 OR revoked_at IS NOT NULL
                OR revoke_reason IS NOT NULL OR is_favorite <> 0 OR favorited_at IS NOT NULL
            """
        ) ?? -1
        guard inferred == 0 else {
            throw DFError.database("v8_chat_v2 不得为历史消息回填编辑/撤回/收藏：\(inferred) 行")
        }

        // 新表与 FTS 必须为空
        for table in newTables {
            let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? -1
            guard count == 0 else {
                throw DFError.database("v8_chat_v2 不得预置数据：\(table) 有 \(count) 行")
            }
        }

        // 不得影响既有记忆检索对象
        let memoryObjectsAfter = try memoryObjects(db)
        guard memoryObjectsAfter == memoryObjectsBefore else {
            throw DFError.database("v8_chat_v2 影响了记忆检索对象")
        }

        let quick = try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "unknown"
        guard quick.lowercased() == "ok" else {
            throw DFError.database("v8_chat_v2 迁移后 quick_check 失败：\(quick)")
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
        let expected = try SchemaMeta.expectedPrefixIncluding(current: .v8_chat_v2, appliedBefore: appliedBefore)
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

        try SchemaMeta.write(db, key: SchemaMetaKey.schemaVersion, value: MigrationID.v8_chat_v2.rawValue, at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.appliedPhase, value: "V2-P7", at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.expectedMigrations, value: String(expected.count), at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.migratedAt, value: String(now), at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.migrationBatch, value: batch, at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.ledgerDigest, value: digest, at: now)
    }
}

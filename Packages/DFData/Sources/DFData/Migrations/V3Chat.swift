import Foundation
import GRDB
import DFCore

/// `v3_chat` 迁移：消息组 + 引用关系 + `messages` 两列。
///
/// 边界（P1.5 A2）：
/// - 只做 DDL、结构校验与 `schema_meta` 写入；
/// - **不重写、不删除、不修改任何历史消息行**（`ADD COLUMN` 只改 schema，不回写数据页）；
/// - 历史消息的 `group_id` / `seq_in_group` 保持 NULL，按虚拟组进入上下文；
/// - 不动 `v1_phase1` / `v2_memory` 的任何既有 DDL。
enum V3Chat {
    /// messages 在 v2 结束时的 14 列（仅作验收比对基线，顺序固定）
    static let legacyColumns = [
        "id", "client_uuid", "conversation_id", "role", "kind", "text", "status",
        "origin", "reply_to_id", "created_at", "sent_at", "model_config_id",
        "emotion_state_id", "deleted_at"
    ]

    /// 迁移耗时上限（秒）：仅 DDL，正常应在毫秒级完成
    static let timeLimit: TimeInterval = 30

    static func migrate(_ db: Database) throws {
        let startedAt = Date()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let batch = "P1.5-v3_chat-\(now)"

        // 0. 前置断言：必须是 v2 库、新表不存在、messages 尚无 group_id
        try assertUpgradable(db)

        // 1. 迁移前快照（用于 M04/M05/M06 校验）
        let messagesBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? 0
        let deletedBefore = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM messages WHERE deleted_at IS NOT NULL"
        ) ?? 0
        let columnsBefore = try messageColumns(db)
        let fingerprintBefore = try messageFingerprint(db)
        let memoryObjectsBefore = try memoryObjects(db)
        let previous = try previousMeta(db)

        // 2. 新表
        try createChatTables(db)

        // 3. messages 加两列（只改 schema，不重写历史行）
        try addMessageColumns(db)

        // 4. 索引（含 seq 部分唯一索引）
        try createIndexes(db)

        // 5. 哨兵：新表可读写（插入后立即删除，不残留）
        try sentinelRoundTrip(db, now: now)

        // 6. 校验：历史行不变、列数正确、新对象齐全、记忆系统未受影响
        try validate(
            db,
            messagesBefore: messagesBefore,
            deletedBefore: deletedBefore,
            columnsBefore: columnsBefore,
            fingerprintBefore: fingerprintBefore,
            memoryObjectsBefore: memoryObjectsBefore
        )

        // 7. schema_meta（含 previous_* 三键）
        try writeMeta(db, now: now, batch: batch, previous: previous)

        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed <= timeLimit else {
            throw DFError.database(
                String(format: "v3_chat 迁移耗时 %.1fs，超过 %.0f 秒上限", elapsed, timeLimit)
            )
        }
    }

    // MARK: - 0. 前置断言

    private static func assertUpgradable(_ db: Database) throws {
        guard let version = try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion) else {
            throw DFError.database("v3_chat 需要 schema_meta.schema_version，当前缺失")
        }
        guard version == MigrationID.v2_memory.rawValue else {
            throw DFError.database(
                "v3_chat 只能从 \(MigrationID.v2_memory.rawValue) 升级，当前为 \(version)"
            )
        }

        let existing = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('message_groups','message_references')"
        ) ?? 0
        guard existing == 0 else {
            throw DFError.database("message_groups / message_references 已存在，v3_chat 不可重复执行")
        }

        guard !(try hasColumn(db, table: "messages", column: "group_id")) else {
            throw DFError.database("messages.group_id 已存在，v3_chat 不可重复执行")
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

    /// 14 列逐行指纹：按 `id` 排序后拼接。
    /// 用 SQLite 内建 `quote()` 统一取值，NULL → `NULL`、文本 → 带引号，
    /// 避免用 Swift 侧类型转换把 INTEGER 误判成 NULL。
    static func messageFingerprint(_ db: Database) throws -> String {
        let columns = legacyColumns.map { "quote(\($0))" }.joined(separator: " || char(31) || ")
        let lines = try String.fetchAll(
            db,
            sql: "SELECT \(columns) AS line FROM messages ORDER BY id"
        )
        return SHA256.hash(lines.joined(separator: "\u{1E}"))
    }

    private static func memoryObjects(_ db: Database) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
            SELECT name FROM sqlite_master
            WHERE name IN ('memories','memory_fts','memory_scopes',
                           'v_memory_user','v_memory_shared','v_memory_self','v_memory_stats')
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

    // MARK: - 2. 建表

    private static func createChatTables(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE message_groups (
            id TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            turn_index INTEGER NOT NULL,
            kind TEXT NOT NULL DEFAULT 'chat',
            status TEXT NOT NULL DEFAULT 'open',
            opened_at INTEGER NOT NULL,
            closed_at INTEGER,
            user_message_id TEXT,
            assistant_message_id TEXT
        )
        """)

        try db.execute(sql: """
        CREATE TABLE message_references (
            message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
            ref_message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
            relation TEXT NOT NULL DEFAULT 'context',
            confidence REAL NOT NULL DEFAULT 1.0,
            reason TEXT,
            created_at INTEGER NOT NULL,
            PRIMARY KEY (message_id, ref_message_id, relation)
        )
        """)
    }

    // MARK: - 3. 加列

    private static func addMessageColumns(_ db: Database) throws {
        try db.execute(sql: """
        ALTER TABLE messages ADD COLUMN group_id TEXT REFERENCES message_groups(id)
        """)
        try db.execute(sql: "ALTER TABLE messages ADD COLUMN seq_in_group INTEGER")
    }

    // MARK: - 4. 索引

    private static func createIndexes(_ db: Database) throws {
        try db.execute(sql: """
        CREATE UNIQUE INDEX ux_message_groups_turn ON message_groups(conversation_id, turn_index)
        """)
        try db.execute(sql: """
        CREATE INDEX ix_message_groups_status ON message_groups(conversation_id, status)
        """)
        // 部分唯一索引：只约束真实组内序号，历史消息两列均为 NULL 时不参与
        try db.execute(sql: """
        CREATE UNIQUE INDEX ux_messages_group_seq ON messages(group_id, seq_in_group)
        WHERE group_id IS NOT NULL AND seq_in_group IS NOT NULL
        """)
        try db.execute(sql: "CREATE INDEX ix_message_refs_ref ON message_references(ref_message_id)")
    }

    // MARK: - 5. 哨兵写入

    /// 用一条临时会话 + 临时组 + 临时消息验证新表与新列可写，随后全部删除。
    /// 不依赖库中已有会话（空库迁移同样成立），也不触碰任何历史行。
    private static func sentinelRoundTrip(_ db: Database, now: Int64) throws {
        try db.execute(
            sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('__v3_sentinel_conv__', 'v3 sentinel', 'sentinel', ?, ?)
            """,
            arguments: [now, now]
        )
        try db.execute(
            sql: """
            INSERT INTO message_groups (id, conversation_id, turn_index, kind, status, opened_at)
            VALUES ('__v3_sentinel_group__', '__v3_sentinel_conv__', 0, 'chat', 'open', ?)
            """,
            arguments: [now]
        )
        try db.execute(
            sql: """
            INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin,
                                  created_at, group_id, seq_in_group)
            VALUES ('__v3_sentinel_msg__', '__v3_sentinel_uuid__', '__v3_sentinel_conv__',
                    'user', 'text', 'sentinel', 'sent', 'user', ?,
                    '__v3_sentinel_group__', 0)
            """,
            arguments: [now]
        )

        let written = try Int.fetchOne(
            db,
            sql: """
            SELECT count(*) FROM messages
            WHERE id = '__v3_sentinel_msg__' AND group_id = '__v3_sentinel_group__' AND seq_in_group = 0
            """
        ) ?? 0

        try db.execute(sql: "DELETE FROM messages WHERE id = '__v3_sentinel_msg__'")
        try db.execute(sql: "DELETE FROM message_groups WHERE id = '__v3_sentinel_group__'")
        try db.execute(sql: "DELETE FROM conversations WHERE id = '__v3_sentinel_conv__'")

        guard written == 1 else {
            throw DFError.database("v3_chat 哨兵写入失败：messages 新列不可写")
        }
    }

    // MARK: - 6. 校验

    private static func validate(
        _ db: Database,
        messagesBefore: Int,
        deletedBefore: Int,
        columnsBefore: [String],
        fingerprintBefore: String,
        memoryObjectsBefore: [String]
    ) throws {
        let messagesAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? -1
        guard messagesAfter == messagesBefore else {
            throw DFError.database("v3_chat 改变了消息行数：\(messagesBefore) → \(messagesAfter)")
        }

        let deletedAfter = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM messages WHERE deleted_at IS NOT NULL"
        ) ?? -1
        guard deletedAfter == deletedBefore else {
            throw DFError.database("v3_chat 改变了软删行数：\(deletedBefore) → \(deletedAfter)")
        }

        let fingerprintAfter = try messageFingerprint(db)
        guard fingerprintAfter == fingerprintBefore else {
            throw DFError.database("v3_chat 改动了历史消息内容（指纹不一致）")
        }

        let columnsAfter = try messageColumns(db)
        guard columnsAfter.count == Self.legacyColumns.count + 2 else {
            throw DFError.database("v3_chat 后 messages 列数应为 16，实际 \(columnsAfter.count)")
        }
        guard Array(columnsAfter.prefix(Self.legacyColumns.count)) == columnsBefore,
              Array(columnsAfter.prefix(Self.legacyColumns.count)) == Self.legacyColumns else {
            throw DFError.database("v3_chat 改变了 messages 既有列的顺序或名称")
        }

        let memoryObjectsAfter = try memoryObjects(db)
        guard memoryObjectsAfter == memoryObjectsBefore else {
            throw DFError.database("v3_chat 影响了记忆系统对象")
        }

        // 历史行两列必须为 NULL（Q2：不回溯分组）
        let grouped = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM messages WHERE group_id IS NOT NULL OR seq_in_group IS NOT NULL"
        ) ?? -1
        guard grouped == 0 else {
            throw DFError.database("v3_chat 不得为历史消息回填分组信息")
        }
    }

    // MARK: - 7. schema_meta

    private static func writeMeta(
        _ db: Database,
        now: Int64,
        batch: String,
        previous: [String: String]
    ) throws {
        let appliedBefore = try SchemaMeta.appliedIdentifiers(db)
        let expected = try SchemaMeta.expectedPrefixIncluding(current: .v3_chat, appliedBefore: appliedBefore)
        let digest = MigrationLedger.digest(prefix: expected)

        // previous_* 只在存在旧值时才写（v1 直升级路径下 v2 的元数据可能缺失）
        if let value = previous[SchemaMetaKey.schemaVersion] {
            try SchemaMeta.write(db, key: SchemaMetaKey.previousSchemaVersion, value: value, at: now)
        }
        if let value = previous[SchemaMetaKey.migrationBatch] {
            try SchemaMeta.write(db, key: SchemaMetaKey.previousMigrationBatch, value: value, at: now)
        }
        if let value = previous[SchemaMetaKey.migratedAt] {
            try SchemaMeta.write(db, key: SchemaMetaKey.previousMigratedAt, value: value, at: now)
        }

        try SchemaMeta.write(db, key: SchemaMetaKey.schemaVersion, value: MigrationID.v3_chat.rawValue, at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.appliedPhase, value: "P1.5", at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.expectedMigrations, value: String(expected.count), at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.migratedAt, value: String(now), at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.migrationBatch, value: batch, at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.ledgerDigest, value: digest, at: now)
    }
}

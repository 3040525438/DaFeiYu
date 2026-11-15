import Foundation
import GRDB
import DFCore

/// v14：消息整理（D26 收藏 / 重要标记 / 分类标签）。
///
/// 只追加列、一张标签表与索引，**不修改任何历史行内容**：
/// - `messages.is_important` / `messages.important_at`：重要标记；
/// - `message_tags`：消息级分类标签，一条消息同一标签只保留一行；
/// - 收藏沿用 v8 已有的 `is_favorite`，本迁移不改其语义。
///
/// 口径：收藏、重要、标签都只是消息级整理信息，**不产生记忆、不改人格**（D26）。
enum V14MessageOrganization {
    static let timeLimit: TimeInterval = 5

    static func migrate(_ db: Database) throws {
        let startedAt = Date()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let batch = "V2-v14_message_organization-\(now)"

        try assertUpgradable(db)

        let messagesBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? 0
        let memoriesBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM memories") ?? 0
        let diaryBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM diary_entries") ?? 0
        let personaItemsBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM persona_items") ?? 0
        let previous = try previousMeta(db)

        try addColumns(db)
        try createTable(db)
        try sentinelRoundTrip(db, now: now)

        let messagesAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? 0
        let memoriesAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM memories") ?? 0
        let diaryAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM diary_entries") ?? 0
        let personaItemsAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM persona_items") ?? 0
        guard messagesBefore == messagesAfter else {
            throw DFError.database("v14_message_organization 迁移改动了 messages 行数")
        }
        guard memoriesBefore == memoriesAfter else {
            throw DFError.database("v14_message_organization 迁移改动了 memories 行数")
        }
        guard diaryBefore == diaryAfter else {
            throw DFError.database("v14_message_organization 迁移改动了 diary_entries 行数")
        }
        guard personaItemsBefore == personaItemsAfter else {
            throw DFError.database("v14_message_organization 迁移改动了 persona_items 行数")
        }

        try writeMeta(db, now: now, batch: batch, previous: previous)

        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed <= timeLimit else {
            throw DFError.database(
                String(format: "v14_message_organization 迁移耗时 %.1fs，超过 %.0f 秒上限", elapsed, timeLimit)
            )
        }
    }

    // MARK: - 0. 前置断言

    private static func assertUpgradable(_ db: Database) throws {
        guard let version = try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion) else {
            throw DFError.database("v14_message_organization 需要 schema_meta.schema_version，当前缺失")
        }
        guard version == MigrationID.v13_cost_ledger.rawValue else {
            throw DFError.database(
                "v14_message_organization 只能从 \(MigrationID.v13_cost_ledger.rawValue) 升级，当前为 \(version)"
            )
        }
        guard try db.tableExists("messages"), try db.tableExists("persona_items") else {
            throw DFError.database("v14_message_organization 缺少基础业务表，无法升级")
        }
        guard try !db.tableExists("message_tags") else {
            throw DFError.database("v14_message_organization 目标表已存在，迁移状态不一致")
        }
        let existing = try db.columns(in: "messages").map(\.name)
        guard !existing.contains("is_important") else {
            throw DFError.database("v14_message_organization 目标列已存在，迁移状态不一致")
        }
    }

    // MARK: - 1. 追加列

    private static func addColumns(_ db: Database) throws {
        // 默认 0：历史消息一律"未标记重要"，不伪造用户意愿
        try db.execute(sql: "ALTER TABLE messages ADD COLUMN is_important INTEGER NOT NULL DEFAULT 0")
        try db.execute(sql: "ALTER TABLE messages ADD COLUMN important_at INTEGER")
    }

    // MARK: - 2. 建表与索引

    private static func createTable(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE message_tags (
            id         TEXT PRIMARY KEY,
            message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
            tag        TEXT NOT NULL,
            created_at INTEGER NOT NULL
        )
        """)
        try db.execute(
            sql: "CREATE UNIQUE INDEX ux_message_tags ON message_tags(message_id, tag)"
        )
        try db.execute(
            sql: "CREATE INDEX ix_message_tags_tag ON message_tags(tag, created_at)"
        )
        try db.execute(
            sql: "CREATE INDEX ix_messages_important ON messages(is_important, created_at)"
        )
    }

    // MARK: - 3. 哨兵往返

    private static func sentinelRoundTrip(_ db: Database, now: Int64) throws {
        let conversationID = "__v14_sentinel_conv__"
        let messageID = "__v14_sentinel_msg__"
        let tagID = "__v14_sentinel_tag__"

        try db.execute(
            sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES (?, 'v14 sentinel', 'sentinel', ?, ?)
            """,
            arguments: [conversationID, now, now]
        )
        try db.execute(
            sql: """
            INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
            VALUES (?, '__v14_sentinel_uuid__', ?, 'user', 'text', 'sentinel', 'sent', 'user', ?)
            """,
            arguments: [messageID, conversationID, now]
        )

        // 新列默认值必须是 0（未标记），不能凭空把历史消息标成重要
        let defaultValue = try Int.fetchOne(
            db,
            sql: "SELECT is_important FROM messages WHERE id = ?",
            arguments: [messageID]
        ) ?? -1
        guard defaultValue == 0 else {
            throw DFError.database("v14_message_organization 新列默认值异常：\(defaultValue)")
        }

        try db.execute(
            sql: "UPDATE messages SET is_important = 1, important_at = ? WHERE id = ?",
            arguments: [now, messageID]
        )
        try db.execute(
            sql: "INSERT INTO message_tags (id, message_id, tag, created_at) VALUES (?, ?, 'sentinel', ?)",
            arguments: [tagID, messageID, now]
        )

        let written = try Int.fetchOne(
            db,
            sql: """
            SELECT (SELECT count(*) FROM messages WHERE id = ? AND is_important = 1) +
                   (SELECT count(*) FROM message_tags WHERE message_id = ?)
            """,
            arguments: [messageID, messageID]
        ) ?? 0

        try db.execute(sql: "DELETE FROM message_tags WHERE id = ?", arguments: [tagID])
        try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [messageID])
        try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [conversationID])

        guard written == 2 else {
            throw DFError.database("v14_message_organization 哨兵往返失败：新列或标签表不可写")
        }
    }

    // MARK: - 4. schema_meta

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
            current: .v14_message_organization,
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
            value: MigrationID.v14_message_organization.rawValue,
            at: now
        )
        try SchemaMeta.write(db, key: SchemaMetaKey.appliedPhase, value: "V2-P12", at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.expectedMigrations, value: String(expected.count), at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.migratedAt, value: String(now), at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.migrationBatch, value: batch, at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.ledgerDigest, value: digest, at: now)
    }
}

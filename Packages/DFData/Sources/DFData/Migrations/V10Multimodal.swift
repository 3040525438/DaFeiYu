import Foundation
import GRDB
import DFCore

/// `v10_multimodal` 迁移：图片尺寸 / 音频时长 / 缩略图 + OCR/转写文本 + 多图分析记录。
///
/// 边界（决策 D05、D17、D27、D28、D29、D71 / W4-1～W4-6）：
/// - 只做 DDL 与"新列 NULL 默认"，**不回填任何推测数据**：历史附件一律 `width/height/duration_ms/thumbnail` 为 NULL；
/// - OCR 与语音转写都是"派生数据"，单独进 `attachment_texts`，可重算、可删除，不影响原始附件；
/// - 附件正文索引 `attachment_text_fts` 只为全局检索服务，不挂 external content；
/// - 多图分析只记录结果，不替换消息正文。
enum V10Multimodal {
    static let timeLimit: TimeInterval = 60

    static let newTables = [
        "attachment_texts",
        "attachment_text_fts",
        "image_analyses"
    ]

    static let newIndexes = [
        "ux_attachment_texts_kind",
        "ix_attachment_texts_attachment",
        "ix_image_analyses_message",
        "ix_image_analyses_conversation",
        "ix_attachments_kind"
    ]

    /// `attachments` 在 v9 结束时的列（验收比对基线，顺序固定）
    static let legacyAttachmentColumns = [
        "id", "sha256", "kind", "rel_path", "byte_size", "mime", "created_at",
        "deleted_at", "deleted_reason"
    ]

    /// 本迁移追加到 `attachments` 的列
    static let newAttachmentColumns = [
        "width", "height", "duration_ms", "thumbnail_rel_path"
    ]

    static func migrate(_ db: Database) throws {
        let startedAt = Date()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let batch = "V2-v10_multimodal-\(now)"

        try assertUpgradable(db)

        let messageFingerprintBefore = try V3Chat.messageFingerprint(db)
        let messagesBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? 0
        let personaFingerprintBefore = try V4Persona.itemFingerprint(db)
        let attachmentsBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM attachments") ?? 0
        let columnsBefore = try attachmentColumns(db)
        let memoryObjectsBefore = try memoryObjects(db)
        let previous = try previousMeta(db)

        try addAttachmentColumns(db)
        try createTables(db)
        try createFullTextSearch(db)
        try createIndexes(db)
        try sentinelRoundTrip(db, now: now)

        try validate(
            db,
            messageFingerprintBefore: messageFingerprintBefore,
            messagesBefore: messagesBefore,
            personaFingerprintBefore: personaFingerprintBefore,
            attachmentsBefore: attachmentsBefore,
            columnsBefore: columnsBefore,
            memoryObjectsBefore: memoryObjectsBefore
        )

        try writeMeta(db, now: now, batch: batch, previous: previous)

        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed <= timeLimit else {
            throw DFError.database(
                String(format: "v10_multimodal 迁移耗时 %.1fs，超过 %.0f 秒上限", elapsed, timeLimit)
            )
        }
    }

    // MARK: - 0. 前置断言

    private static func assertUpgradable(_ db: Database) throws {
        guard let version = try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion) else {
            throw DFError.database("v10_multimodal 需要 schema_meta.schema_version，当前缺失")
        }
        guard version == MigrationID.v9_astrbot.rawValue else {
            throw DFError.database(
                "v10_multimodal 只能从 \(MigrationID.v9_astrbot.rawValue) 升级，当前为 \(version)"
            )
        }

        let quoted = newTables.map { "'\($0)'" }.joined(separator: ",")
        let existing = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN (\(quoted))"
        ) ?? 0
        guard existing == 0 else {
            throw DFError.database("v10_multimodal 新表已存在，不可重复执行")
        }

        guard !(try hasColumn(db, table: "attachments", column: "width")) else {
            throw DFError.database("attachments.width 已存在，v10_multimodal 不可重复执行")
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

    // MARK: - 2. 附件加列

    private static func addAttachmentColumns(_ db: Database) throws {
        let statements = [
            "ALTER TABLE attachments ADD COLUMN width INTEGER",
            "ALTER TABLE attachments ADD COLUMN height INTEGER",
            "ALTER TABLE attachments ADD COLUMN duration_ms INTEGER",
            "ALTER TABLE attachments ADD COLUMN thumbnail_rel_path TEXT"
        ]
        for statement in statements {
            try db.execute(sql: statement)
        }
    }

    // MARK: - 3. 建表与索引

    private static func createTables(_ db: Database) throws {
        // 派生文本：同一附件的 OCR 与转写各一条，重算即覆盖
        try db.execute(sql: """
        CREATE TABLE attachment_texts (
            id            TEXT PRIMARY KEY,
            attachment_id TEXT NOT NULL REFERENCES attachments(id) ON DELETE CASCADE,
            kind          TEXT NOT NULL,
            text          TEXT NOT NULL,
            language      TEXT,
            engine        TEXT NOT NULL DEFAULT '',
            confidence    REAL,
            created_at    INTEGER NOT NULL,
            updated_at    INTEGER NOT NULL
        )
        """)

        // 多图分析：一次请求对应一行，只记录结果，不改消息正文
        try db.execute(sql: """
        CREATE TABLE image_analyses (
            id                  TEXT PRIMARY KEY,
            conversation_id     TEXT REFERENCES conversations(id) ON DELETE SET NULL,
            message_id          TEXT REFERENCES messages(id) ON DELETE SET NULL,
            attachment_ids_json TEXT NOT NULL DEFAULT '[]',
            prompt              TEXT NOT NULL DEFAULT '',
            result              TEXT NOT NULL DEFAULT '',
            model_config_id     TEXT,
            status              TEXT NOT NULL DEFAULT 'pending',
            created_at          INTEGER NOT NULL,
            finished_at         INTEGER
        )
        """)
    }

    private static func createFullTextSearch(_ db: Database) throws {
        try db.execute(sql: """
        CREATE VIRTUAL TABLE attachment_text_fts USING fts5(
            attachment_id UNINDEXED,
            text_bigram,
            tokenize = 'unicode61'
        )
        """)
    }

    private static func createIndexes(_ db: Database) throws {
        let statements = [
            "CREATE UNIQUE INDEX ux_attachment_texts_kind ON attachment_texts(attachment_id, kind)",
            "CREATE INDEX ix_attachment_texts_attachment ON attachment_texts(kind, updated_at)",
            "CREATE INDEX ix_image_analyses_message ON image_analyses(message_id, created_at)",
            "CREATE INDEX ix_image_analyses_conversation ON image_analyses(conversation_id, created_at)",
            "CREATE INDEX ix_attachments_kind ON attachments(kind, created_at)"
        ]
        for statement in statements {
            try db.execute(sql: statement)
        }
    }

    // MARK: - 4. 哨兵

    private static func sentinelRoundTrip(_ db: Database, now: Int64) throws {
        let conversationID = "__v10_sentinel_conv__"
        let messageID = "__v10_sentinel_msg__"
        let attachmentID = "__v10_sentinel_att__"
        let textID = "__v10_sentinel_text__"
        let analysisID = "__v10_sentinel_analysis__"

        try db.execute(
            sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES (?, 'v10 sentinel', 'sentinel', ?, ?)
            """,
            arguments: [conversationID, now, now]
        )
        try db.execute(
            sql: """
            INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
            VALUES (?, '__v10_sentinel_uuid__', ?, 'user', 'text', 'sentinel', 'sent', 'user', ?)
            """,
            arguments: [messageID, conversationID, now]
        )
        try db.execute(
            sql: """
            INSERT INTO attachments
                (id, sha256, kind, rel_path, byte_size, mime, created_at, width, height, duration_ms, thumbnail_rel_path)
            VALUES (?, '__v10_sentinel_sha__', 'image', 'sentinel.png', 1, 'image/png', ?, 1, 1, NULL, 'thumb.png')
            """,
            arguments: [attachmentID, now]
        )
        try db.execute(
            sql: """
            INSERT INTO attachment_texts
                (id, attachment_id, kind, text, language, engine, confidence, created_at, updated_at)
            VALUES (?, ?, 'ocr', 'sentinel', 'zh', 'test', 1.0, ?, ?)
            """,
            arguments: [textID, attachmentID, now, now]
        )
        try db.execute(
            sql: """
            INSERT INTO attachment_text_fts (attachment_id, text_bigram) VALUES (?, 'sentinel')
            """,
            arguments: [attachmentID]
        )
        try db.execute(
            sql: """
            INSERT INTO image_analyses
                (id, conversation_id, message_id, attachment_ids_json, prompt, result, status, created_at)
            VALUES (?, ?, ?, '[]', 'p', 'r', 'done', ?)
            """,
            arguments: [analysisID, conversationID, messageID, now]
        )

        let written = try Int.fetchOne(
            db,
            sql: """
            SELECT (SELECT count(*) FROM attachment_texts) +
                   (SELECT count(*) FROM attachment_text_fts) +
                   (SELECT count(*) FROM image_analyses)
            """
        ) ?? 0

        try db.execute(sql: "DELETE FROM attachment_text_fts WHERE attachment_id = ?", arguments: [attachmentID])
        try db.execute(sql: "DELETE FROM image_analyses WHERE id = ?", arguments: [analysisID])
        try db.execute(sql: "DELETE FROM attachment_texts WHERE id = ?", arguments: [textID])
        try db.execute(sql: "DELETE FROM attachments WHERE id = ?", arguments: [attachmentID])
        try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [messageID])
        try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [conversationID])

        guard written >= 3 else {
            throw DFError.database("v10_multimodal 哨兵写入失败：新表或 FTS 不可写")
        }
    }

    // MARK: - 5. 校验

    private static func validate(
        _ db: Database,
        messageFingerprintBefore: String,
        messagesBefore: Int,
        personaFingerprintBefore: String,
        attachmentsBefore: Int,
        columnsBefore: [String],
        memoryObjectsBefore: [String]
    ) throws {
        let messageFingerprintAfter = try V3Chat.messageFingerprint(db)
        guard messageFingerprintAfter == messageFingerprintBefore else {
            throw DFError.database("v10_multimodal 改动了历史消息内容（指纹不一致）")
        }
        let messagesAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? -1
        guard messagesAfter == messagesBefore else {
            throw DFError.database("v10_multimodal 改变了消息行数：\(messagesBefore) → \(messagesAfter)")
        }
        let personaFingerprintAfter = try V4Persona.itemFingerprint(db)
        guard personaFingerprintAfter == personaFingerprintBefore else {
            throw DFError.database("v10_multimodal 改动了人格条目内容（指纹不一致）")
        }
        let attachmentsAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM attachments") ?? -1
        guard attachmentsAfter == attachmentsBefore else {
            throw DFError.database("v10_multimodal 改变了附件行数：\(attachmentsBefore) → \(attachmentsAfter)")
        }

        let columnsAfter = try attachmentColumns(db)
        let expectedCount = legacyAttachmentColumns.count + newAttachmentColumns.count
        guard columnsAfter.count == expectedCount else {
            throw DFError.database(
                "v10_multimodal 后 attachments 列数应为 \(expectedCount)，实际 \(columnsAfter.count)"
            )
        }
        guard Array(columnsAfter.prefix(legacyAttachmentColumns.count)) == columnsBefore,
              Array(columnsAfter.prefix(legacyAttachmentColumns.count)) == legacyAttachmentColumns else {
            throw DFError.database("v10_multimodal 改变了 attachments 既有列的顺序或名称")
        }
        guard Array(columnsAfter.suffix(newAttachmentColumns.count)) == newAttachmentColumns else {
            throw DFError.database("v10_multimodal 追加的附件列与预期不一致：\(columnsAfter)")
        }

        // 不得为历史附件伪造尺寸/时长/缩略图
        let inferred = try Int.fetchOne(
            db,
            sql: """
            SELECT count(*) FROM attachments
             WHERE width IS NOT NULL OR height IS NOT NULL
                OR duration_ms IS NOT NULL OR thumbnail_rel_path IS NOT NULL
            """
        ) ?? -1
        guard inferred == 0 else {
            throw DFError.database("v10_multimodal 不得为历史附件回填尺寸/时长/缩略图：\(inferred) 行")
        }

        for table in newTables {
            let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? -1
            guard count == 0 else {
                throw DFError.database("v10_multimodal 不得预置数据：\(table) 有 \(count) 行")
            }
        }

        let memoryObjectsAfter = try memoryObjects(db)
        guard memoryObjectsAfter == memoryObjectsBefore else {
            throw DFError.database("v10_multimodal 影响了记忆检索对象")
        }

        let quick = try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "unknown"
        guard quick.lowercased() == "ok" else {
            throw DFError.database("v10_multimodal 迁移后 quick_check 失败：\(quick)")
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
        let expected = try SchemaMeta.expectedPrefixIncluding(current: .v10_multimodal, appliedBefore: appliedBefore)
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

        try SchemaMeta.write(db, key: SchemaMetaKey.schemaVersion, value: MigrationID.v10_multimodal.rawValue, at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.appliedPhase, value: "V2-P8", at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.expectedMigrations, value: String(expected.count), at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.migratedAt, value: String(now), at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.migrationBatch, value: batch, at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.ledgerDigest, value: digest, at: now)
    }
}

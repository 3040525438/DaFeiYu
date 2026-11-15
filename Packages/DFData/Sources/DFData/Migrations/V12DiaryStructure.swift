import Foundation
import GRDB
import DFCore

/// `v12_diary_structure` 迁移：日记结构化字段（D34）。
///
/// 边界：
/// - 只给 `diary_entries` / `diary_entry_versions` 追加列并建一个索引，**不改任何历史行内容**；
/// - 新列默认空串 / 0，历史日记的"关系变化"保持"未填写、未确认"，不凭空生成结构化信息；
/// - 关系变化只是自然语言记录 + 用户确认标记，关系阶段仍由 `RelationshipService` 负责；
/// - 版本快照同步扩容，保证每次编辑留下的都是全量快照。
enum V12DiaryStructure {
    static let timeLimit: TimeInterval = 60

    /// 本次新增的列（两张表同名）
    static let newColumns = [
        "shared_experience",
        "observation",
        "feeling",
        "relationship_change",
        "relationship_change_confirmed"
    ]

    /// 本次新增的索引
    static let newIndexes = [
        "ix_diary_entries_relation"
    ]

    static func migrate(_ db: Database) throws {
        let startedAt = Date()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let batch = "V2-v12_diary_structure-\(now)"

        try assertUpgradable(db)

        let messageFingerprintBefore = try V3Chat.messageFingerprint(db)
        let messagesBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? 0
        let memoriesBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM memories") ?? 0
        let personaFingerprintBefore = try V4Persona.itemFingerprint(db)
        let configsBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM model_configs") ?? 0
        let diaryFingerprintBefore = try diaryFingerprint(db)
        let versionFingerprintBefore = try versionFingerprint(db)
        let diaryCountBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM diary_entries") ?? 0
        let versionCountBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM diary_entry_versions") ?? 0
        let ftsCountBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM diary_fts") ?? 0
        let previous = try previousMeta(db)

        try addColumns(db)
        try createIndexes(db)
        try sentinelRoundTrip(db, now: now)

        try validate(
            db,
            messageFingerprintBefore: messageFingerprintBefore,
            messagesBefore: messagesBefore,
            memoriesBefore: memoriesBefore,
            personaFingerprintBefore: personaFingerprintBefore,
            configsBefore: configsBefore,
            diaryFingerprintBefore: diaryFingerprintBefore,
            versionFingerprintBefore: versionFingerprintBefore,
            diaryCountBefore: diaryCountBefore,
            versionCountBefore: versionCountBefore,
            ftsCountBefore: ftsCountBefore
        )

        try writeMeta(db, now: now, batch: batch, previous: previous)

        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed <= timeLimit else {
            throw DFError.database(
                String(format: "v12_diary_structure 迁移耗时 %.1fs，超过 %.0f 秒上限", elapsed, timeLimit)
            )
        }
    }

    // MARK: - 0. 前置断言

    private static func assertUpgradable(_ db: Database) throws {
        guard let version = try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion) else {
            throw DFError.database("v12_diary_structure 需要 schema_meta.schema_version，当前缺失")
        }
        guard version == MigrationID.v11_local_models.rawValue else {
            throw DFError.database(
                "v12_diary_structure 只能从 \(MigrationID.v11_local_models.rawValue) 升级，当前为 \(version)"
            )
        }
        guard try db.tableExists("diary_entries"), try db.tableExists("diary_entry_versions") else {
            throw DFError.database("v12_diary_structure 缺少日记表，无法升级")
        }
        for table in ["diary_entries", "diary_entry_versions"] {
            let existing = Set(try String.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info('\(table)')"
            ))
            let conflict = newColumns.filter { existing.contains($0) }
            guard conflict.isEmpty else {
                throw DFError.database(
                    "v12_diary_structure 新列已存在，不可重复执行：\(table).\(conflict.joined(separator: ","))"
                )
            }
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

    // MARK: - 1. 加列与索引

    private static func addColumns(_ db: Database) throws {
        let textColumns = [
            "shared_experience",
            "observation",
            "feeling",
            "relationship_change"
        ]
        for table in ["diary_entries", "diary_entry_versions"] {
            for column in textColumns {
                try db.execute(
                    sql: "ALTER TABLE \(table) ADD COLUMN \(column) TEXT NOT NULL DEFAULT ''"
                )
            }
            try db.execute(
                sql: """
                ALTER TABLE \(table)
                ADD COLUMN relationship_change_confirmed INTEGER NOT NULL DEFAULT 0
                """
            )
        }
    }

    private static func createIndexes(_ db: Database) throws {
        let statements = [
            """
            CREATE INDEX ix_diary_entries_relation
            ON diary_entries(relationship_change_confirmed, entry_date)
            """
        ]
        for statement in statements {
            try db.execute(sql: statement)
        }
    }

    // MARK: - 2. 哨兵

    private static func sentinelRoundTrip(_ db: Database, now: Int64) throws {
        let diaryID = "__v12_sentinel_diary__"
        let versionID = "__v12_sentinel_diary_version__"

        try db.execute(
            sql: """
            INSERT INTO diary_entries
                (id, entry_date, title, content, source, generated_by, is_user_edited,
                 shared_experience, observation, feeling, relationship_change,
                 relationship_change_confirmed, created_at, updated_at)
            VALUES (?, '1900-01-01', '哨兵', '哨兵正文', 'manual', 'migration', 0,
                    '一起散步', '她走得更慢', '安心', '更亲近了一点', 0, ?, ?)
            """,
            arguments: [diaryID, now, now]
        )
        try db.execute(
            sql: """
            INSERT INTO diary_entry_versions
                (id, diary_id, version, title, content, change_reason, changed_by, created_at,
                 shared_experience, observation, feeling, relationship_change,
                 relationship_change_confirmed)
            VALUES (?, ?, 1, '哨兵', '哨兵正文', 'sentinel', 'migration', ?,
                    '一起散步', '她走得更慢', '安心', '更亲近了一点', 0)
            """,
            arguments: [versionID, diaryID, now]
        )

        let entry = try Row.fetchOne(
            db,
            sql: """
            SELECT shared_experience, observation, feeling, relationship_change,
                   relationship_change_confirmed
              FROM diary_entries WHERE id = ?
            """,
            arguments: [diaryID]
        )
        let version = try Row.fetchOne(
            db,
            sql: """
            SELECT shared_experience, relationship_change, relationship_change_confirmed
              FROM diary_entry_versions WHERE id = ?
            """,
            arguments: [versionID]
        )
        let ok = String.fromDatabaseValue(entry?["shared_experience"] ?? .null) == "一起散步"
            && String.fromDatabaseValue(entry?["relationship_change"] ?? .null) == "更亲近了一点"
            && Int.fromDatabaseValue(entry?["relationship_change_confirmed"] ?? .null) == 0
            && String.fromDatabaseValue(version?["shared_experience"] ?? .null) == "一起散步"
            && String.fromDatabaseValue(version?["relationship_change"] ?? .null) == "更亲近了一点"

        try db.execute(sql: "DELETE FROM diary_entry_versions WHERE id = ?", arguments: [versionID])
        try db.execute(sql: "DELETE FROM diary_entries WHERE id = ?", arguments: [diaryID])

        guard ok else {
            throw DFError.database("v12_diary_structure 哨兵写入失败：新列不可读写")
        }
    }

    // MARK: - 3. 校验

    private static func validate(
        _ db: Database,
        messageFingerprintBefore: String,
        messagesBefore: Int,
        memoriesBefore: Int,
        personaFingerprintBefore: String,
        configsBefore: Int,
        diaryFingerprintBefore: String,
        versionFingerprintBefore: String,
        diaryCountBefore: Int,
        versionCountBefore: Int,
        ftsCountBefore: Int
    ) throws {
        guard try V3Chat.messageFingerprint(db) == messageFingerprintBefore else {
            throw DFError.database("v12_diary_structure 改动了历史消息内容（指纹不一致）")
        }
        let messagesAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? -1
        guard messagesAfter == messagesBefore else {
            throw DFError.database("v12_diary_structure 改变了消息行数：\(messagesBefore) → \(messagesAfter)")
        }
        let memoriesAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM memories") ?? -1
        guard memoriesAfter == memoriesBefore else {
            throw DFError.database("v12_diary_structure 改变了记忆行数：\(memoriesBefore) → \(memoriesAfter)")
        }
        guard try V4Persona.itemFingerprint(db) == personaFingerprintBefore else {
            throw DFError.database("v12_diary_structure 改动了人格条目内容（指纹不一致）")
        }
        let configsAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM model_configs") ?? -1
        guard configsAfter == configsBefore else {
            throw DFError.database("v12_diary_structure 改变了模型配置行数：\(configsBefore) → \(configsAfter)")
        }

        guard try diaryFingerprint(db) == diaryFingerprintBefore else {
            throw DFError.database("v12_diary_structure 改动了历史日记内容（指纹不一致）")
        }
        guard try versionFingerprint(db) == versionFingerprintBefore else {
            throw DFError.database("v12_diary_structure 改动了日记版本快照（指纹不一致）")
        }
        let diaryCountAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM diary_entries") ?? -1
        guard diaryCountAfter == diaryCountBefore else {
            throw DFError.database("v12_diary_structure 改变了日记行数：\(diaryCountBefore) → \(diaryCountAfter)")
        }
        let versionCountAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM diary_entry_versions") ?? -1
        guard versionCountAfter == versionCountBefore else {
            throw DFError.database(
                "v12_diary_structure 改变了日记版本行数：\(versionCountBefore) → \(versionCountAfter)"
            )
        }

        // 历史日记不得被"补写"结构化内容
        let fabricated = try Int.fetchOne(
            db,
            sql: """
            SELECT count(*) FROM diary_entries
             WHERE shared_experience <> '' OR observation <> ''
                OR feeling <> '' OR relationship_change <> ''
                OR relationship_change_confirmed <> 0
            """
        ) ?? -1
        guard fabricated == 0 else {
            throw DFError.database("v12_diary_structure 不得为历史日记补写结构化内容：\(fabricated) 行")
        }

        let ftsCountAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM diary_fts") ?? -1
        guard ftsCountAfter == ftsCountBefore else {
            throw DFError.database("v12_diary_structure 改变了日记全文索引：\(ftsCountBefore) → \(ftsCountAfter)")
        }

        let quick = try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "unknown"
        guard quick.lowercased() == "ok" else {
            throw DFError.database("v12_diary_structure 迁移后 quick_check 失败：\(quick)")
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
        let expected = try SchemaMeta.expectedPrefixIncluding(current: .v12_diary_structure, appliedBefore: appliedBefore)
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

        try SchemaMeta.write(db, key: SchemaMetaKey.schemaVersion, value: MigrationID.v12_diary_structure.rawValue, at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.appliedPhase, value: "V2-P10", at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.expectedMigrations, value: String(expected.count), at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.migratedAt, value: String(now), at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.migrationBatch, value: batch, at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.ledgerDigest, value: digest, at: now)
    }

    // MARK: - 5. 指纹

    /// 日记正文指纹：只覆盖升级前已有的列，用于证明"加列不改历史内容"。
    static func diaryFingerprint(_ db: Database) throws -> String {
        let text = try String.fetchOne(
            db,
            sql: """
            SELECT group_concat(line, char(10)) FROM (
                SELECT quote(id) || '|' || quote(entry_date) || '|' || quote(title) || '|'
                    || quote(content) || '|' || quote(mood_code) || '|' || quote(source) || '|'
                    || quote(generated_by) || '|' || is_user_edited || '|' || quote(memory_id) || '|'
                    || created_at || '|' || updated_at || '|' || quote(deleted_at) AS line
                  FROM diary_entries ORDER BY id
            )
            """
        ) ?? ""
        return SHA256.hash(text)
    }

    /// 版本快照指纹：同上，只覆盖升级前已有的列。
    static func versionFingerprint(_ db: Database) throws -> String {
        let text = try String.fetchOne(
            db,
            sql: """
            SELECT group_concat(line, char(10)) FROM (
                SELECT quote(id) || '|' || quote(diary_id) || '|' || version || '|'
                    || quote(title) || '|' || quote(content) || '|' || quote(change_reason) || '|'
                    || quote(changed_by) || '|' || created_at AS line
                  FROM diary_entry_versions ORDER BY id
            )
            """
        ) ?? ""
        return SHA256.hash(text)
    }
}

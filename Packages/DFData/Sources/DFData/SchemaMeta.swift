import Foundation
import GRDB
import DFCore

/// `schema_meta` 的固定键（不在运行时随意新增语义）。
public enum SchemaMetaKey {
    public static let schemaVersion = "schema_version"
    public static let appliedPhase = "applied_phase"
    public static let migrationBatch = "migration_batch"
    public static let migratedAt = "migrated_at"
    public static let ledgerDigest = "ledger_digest"
    public static let expectedMigrations = "expected_migrations"
    /// v3 起：保留上一版元数据，避免 `migrated_at` 变化被误判为台账被改
    public static let previousSchemaVersion = "previous_schema_version"
    public static let previousMigrationBatch = "previous_migration_batch"
    public static let previousMigratedAt = "previous_migrated_at"
}

public enum SchemaMetaError: Error, Equatable, CustomStringConvertible {
    case tableMissing
    case keyMissing(String)
    case versionMismatch(meta: String, ledger: String)
    case digestMismatch(meta: String, computed: String)
    case countMismatch(meta: String, ledger: Int)
    case ledgerEmpty
    case missingObjects([String])

    public var description: String {
        switch self {
        case .tableMissing:
            return "缺少 schema_meta 表，数据库可能未完成迁移"
        case .keyMissing(let key):
            return "schema_meta 缺少键：\(key)"
        case .versionMismatch(let meta, let ledger):
            return "版本不一致：schema_meta=\(meta)，台账=\(ledger)"
        case .digestMismatch(let meta, let computed):
            return "台账摘要不一致：schema_meta=\(meta)，重算=\(computed)"
        case .countMismatch(let meta, let ledger):
            return "迁移数量不一致：schema_meta=\(meta)，台账=\(ledger)"
        case .ledgerEmpty:
            return "迁移台账为空"
        case .missingObjects(let names):
            return "升级后缺少必需对象：\(names.joined(separator: ", "))"
        }
    }
}

/// `schema_meta` 的读写与一致性校验。
///
/// 职责边界：
/// - `grdb_migrations`（GRDB 所有）：只表示"哪些迁移真的执行过"；
/// - `schema_meta`（应用所有）：表示"当前业务版本 / 阶段 / 批次 / 台账摘要"。
/// 两者不各自保存完整清单，避免形成双事实源。
public enum SchemaMeta {
    public static func createTable(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE schema_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at INTEGER NOT NULL
        )
        """)
    }

    public static func tableExists(_ db: Database) throws -> Bool {
        let count = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='schema_meta'"
        ) ?? 0
        return count > 0
    }

    public static func value(_ db: Database, key: String) throws -> String? {
        guard try tableExists(db) else { return nil }
        return try String.fetchOne(db, sql: "SELECT value FROM schema_meta WHERE key = ?", arguments: [key])
    }

    public static func write(_ db: Database, key: String, value: String, at millis: Int64) throws {
        try db.execute(
            sql: """
            INSERT INTO schema_meta (key, value, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
            """,
            arguments: [key, value, millis]
        )
    }

    /// 台账里的 identifier 集合（顺序无意义，由规范清单决定顺序）
    public static func appliedIdentifiers(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
    }

    /// 启动自检：校验 meta 与台账是否自相一致。
    /// - Returns: 当前版本号（规范顺序的最后一项）
    public static func verify(_ db: Database) throws -> String {
        guard try tableExists(db) else { throw SchemaMetaError.tableMissing }

        let applied = try appliedIdentifiers(db)
        guard !applied.isEmpty else { throw SchemaMetaError.ledgerEmpty }
        let ordered = try MigrationLedger.validatedPrefix(applied: applied)

        guard let ledgerVersion = ordered.last else { throw SchemaMetaError.ledgerEmpty }
        let computedDigest = MigrationLedger.digest(prefix: ordered)

        guard let metaVersion = try value(db, key: SchemaMetaKey.schemaVersion) else {
            throw SchemaMetaError.keyMissing(SchemaMetaKey.schemaVersion)
        }
        guard let metaDigest = try value(db, key: SchemaMetaKey.ledgerDigest) else {
            throw SchemaMetaError.keyMissing(SchemaMetaKey.ledgerDigest)
        }
        let metaCount = try value(db, key: SchemaMetaKey.expectedMigrations)

        guard metaVersion == ledgerVersion else {
            throw SchemaMetaError.versionMismatch(meta: metaVersion, ledger: ledgerVersion)
        }
        guard metaDigest == computedDigest else {
            throw SchemaMetaError.digestMismatch(meta: metaDigest, computed: computedDigest)
        }
        guard metaCount == String(ordered.count) else {
            throw SchemaMetaError.countMismatch(meta: metaCount ?? "nil", ledger: ordered.count)
        }
        return metaVersion
    }

    /// 各迁移阶段新增的必需对象（按阶段分组，校验到目标版本为止）。
    /// 名字全部来自本文件常量，不拼接外部输入。
    private static let requiredObjectsByMigration: [(id: MigrationID, objects: [String])] = [
        (.v2_memory, [
            "schema_meta",
            "memory_scopes",
            "memory_fts",
            "v_memory_user",
            "v_memory_shared",
            "v_memory_self",
            "v_memory_stats",
            "ux_memories_dedupe",
            "ix_memories_scope_time",
            "ix_persona_items_tier"
        ]),
        (.v3_chat, [
            "message_groups",
            "message_references",
            "ux_message_groups_turn",
            "ix_message_groups_status",
            "ux_messages_group_seq",
            "ix_message_refs_ref"
        ]),
        (.v4_persona, [
            "relationship_profile",
            "relationship_stage_history",
            "relationship_milestones",
            "persona_fingerprints",
            "persona_imports",
            "ix_relationship_stage_time",
            "ix_relationship_stage_status",
            "ix_relationship_milestones_time",
            "ix_relationship_milestones_kind",
            "ux_persona_fingerprints",
            "ix_persona_imports_time"
        ]),
        (.v5_autonomy, [
            "conversation_topics",
            "conversation_intents",
            "autonomy_tasks",
            "autonomy_runs",
            "autonomy_controls",
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
        ]),
        (.v6_character, [
            "characters",
            "character_moods",
            "character_states",
            "character_state_history",
            "ix_character_moods_char",
            "ux_character_moods_code",
            "ux_character_states_char",
            "ix_character_state_history_time",
            "ix_proactive_messages_feedback"
        ]),
        (.v7_meta_backup, [
            "backup_manifests",
            "restore_logs",
            "upgrade_records",
            "ix_backup_manifests_time",
            "ix_backup_manifests_status",
            "ix_restore_logs_backup",
            "ix_restore_logs_status",
            "ix_upgrade_records_time",
            "ix_attachments_deleted"
        ]),
        (.v8_chat_v2, [
            "message_edits",
            "diary_entries",
            "diary_entry_versions",
            "message_fts",
            "diary_fts",
            "ix_message_edits_message",
            "ux_message_edits_version",
            "ux_diary_entries_date",
            "ix_diary_entries_updated",
            "ux_diary_versions",
            "ix_messages_favorite",
            "ix_messages_revoked"
        ]),
        (.v9_astrbot, [
            "astrbot_migration_batches",
            "astrbot_id_map",
            "astrbot_import_pending",
            "ix_astrbot_batches_time",
            "ix_astrbot_batches_status",
            "ux_astrbot_id_map",
            "ix_astrbot_pending_batch",
            "ix_astrbot_pending_kind"
        ])
    ]

    /// 升级后必须存在的对象（结构 + 必要索引）。
    /// 只做存在性检查，不校验 DDL 细节；用于"迁移成功后能否恢复读写"的门禁。
    /// - Parameter last: 校验目标版本，默认生产最终版本；旧版本测试须显式传入，避免被新迁移牵连。
    ///
    /// 数量演进：v3 由 10 项扩为 16 项；v4 再扩 11 项（共 27）；v5 再扩 16 项（共 43）；v6 再扩 9 项（共 52）；
    /// v7 再扩 9 项（共 61）；v8 再扩 12 项（共 73）；v9 再扩 8 项（共 81）。
    public static func verifyRequiredObjects(_ db: Database, upTo last: MigrationID = Migrations.latest) throws {
        let allCases = MigrationID.allCases
        guard let boundary = allCases.firstIndex(of: last) else { return }
        let required = requiredObjectsByMigration
            .filter { entry in
                guard let index = allCases.firstIndex(of: entry.id) else { return false }
                return index <= boundary
            }
            .flatMap { $0.objects }

        let quoted = required.map { "'\($0)'" }.joined(separator: ",")
        let found = try String.fetchAll(
            db,
            sql: "SELECT name FROM sqlite_master WHERE name IN (\(quoted))"
        )
        let missing = required.filter { !found.contains($0) }
        guard missing.isEmpty else {
            throw SchemaMetaError.missingObjects(missing)
        }
    }

    /// 迁移体内计算"含本次"的摘要目标。
    /// 时序：GRDB 在迁移体执行**之后**才写入本次 identifier，
    /// 因此这里用"已有条数 + 1"推导预期前缀。
    public static func expectedPrefixIncluding(current: MigrationID, appliedBefore: [String]) throws -> [String] {
        let before = try MigrationLedger.validatedPrefix(applied: appliedBefore)
        let expected = MigrationLedger.expectedPrefix(count: before.count + 1)
        guard expected.last == current.rawValue else {
            throw MigrationOrderError.unexpectedCurrent(current.rawValue, expected: expected.last ?? "nil")
        }
        return expected
    }
}

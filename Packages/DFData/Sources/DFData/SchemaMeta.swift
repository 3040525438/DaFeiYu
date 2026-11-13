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

    /// 升级后必须存在的对象（结构 + 必要索引）。
    /// 只做存在性检查，不校验 DDL 细节；用于"迁移成功后能否恢复读写"的门禁。
    public static func verifyRequiredObjects(_ db: Database) throws {
        let required = [
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
        ]
        // 名字全部来自本文件常量，不拼接外部输入
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

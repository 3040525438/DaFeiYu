import Foundation
import GRDB
import DFCore

/// v13：D10 成本审计台账。
///
/// 只新增一张 `cost_ledger`，不改任何历史表；升级前后校验消息/记忆/人格条数不变。
/// 记账口径（与 `DFCore` 的 `CostKind` 对齐）：
/// - `confirmed`：服务端返回用量 + 已知单价；
/// - `estimated`：用量或单价缺失，按可解释规则估算；
/// - `unavailable`：两者都缺，`cost_yuan` 必须为 NULL（禁止写 0 冒充）。
enum V13CostLedger {
    static let timeLimit: TimeInterval = 5

    static func migrate(_ db: Database) throws {
        let startedAt = Date()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let batch = "V2-v13_cost_ledger-\(now)"

        try assertUpgradable(db)

        let messagesBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? 0
        let memoriesBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM memories") ?? 0
        let personaItemsBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM persona_items") ?? 0
        let previous = try previousMeta(db)

        try createTable(db)
        try sentinelRoundTrip(db, now: now)

        let messagesAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? 0
        let memoriesAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM memories") ?? 0
        let personaItemsAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM persona_items") ?? 0
        guard messagesBefore == messagesAfter else {
            throw DFError.database("v13_cost_ledger 迁移改动了 messages 行数")
        }
        guard memoriesBefore == memoriesAfter else {
            throw DFError.database("v13_cost_ledger 迁移改动了 memories 行数")
        }
        guard personaItemsBefore == personaItemsAfter else {
            throw DFError.database("v13_cost_ledger 迁移改动了 persona_items 行数")
        }

        try writeMeta(db, now: now, batch: batch, previous: previous)

        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed <= timeLimit else {
            throw DFError.database(
                String(format: "v13_cost_ledger 迁移耗时 %.1fs，超过 %.0f 秒上限", elapsed, timeLimit)
            )
        }
    }

    // MARK: - 0. 前置断言

    private static func assertUpgradable(_ db: Database) throws {
        guard let version = try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion) else {
            throw DFError.database("v13_cost_ledger 需要 schema_meta.schema_version，当前缺失")
        }
        guard version == MigrationID.v12_diary_structure.rawValue else {
            throw DFError.database(
                "v13_cost_ledger 只能从 \(MigrationID.v12_diary_structure.rawValue) 升级，当前为 \(version)"
            )
        }
        guard try db.tableExists("messages"), try db.tableExists("persona_items") else {
            throw DFError.database("v13_cost_ledger 缺少基础业务表，无法升级")
        }
        guard try !db.tableExists("cost_ledger") else {
            throw DFError.database("v13_cost_ledger 目标表已存在，迁移状态不一致")
        }
    }

    // MARK: - 1. 建表

    private static func createTable(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE cost_ledger (
            id TEXT PRIMARY KEY,
            day_key TEXT NOT NULL,
            scope TEXT NOT NULL CHECK (scope IN ('chat', 'autonomy')),
            ref_id TEXT,
            provider TEXT NOT NULL,
            model_id TEXT NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('reserved', 'settled', 'failed', 'cancelled')),
            cost_kind TEXT NOT NULL CHECK (cost_kind IN ('confirmed', 'estimated', 'unavailable')),
            cost_yuan REAL,
            prompt_tokens INTEGER,
            completion_tokens INTEGER,
            currency TEXT NOT NULL DEFAULT 'CNY',
            note TEXT,
            created_at INTEGER NOT NULL,
            settled_at INTEGER,
            CHECK (
                (cost_kind = 'unavailable' AND cost_yuan IS NULL)
                OR (cost_kind <> 'unavailable' AND cost_yuan IS NOT NULL)
            )
        )
        """)
        try db.execute(sql: "CREATE INDEX ix_cost_ledger_day ON cost_ledger(day_key, scope)")
        try db.execute(sql: "CREATE INDEX ix_cost_ledger_created ON cost_ledger(created_at)")
    }

    // MARK: - 2. 哨兵往返

    private static func sentinelRoundTrip(_ db: Database, now: Int64) throws {
        let id = "migration-sentinel-v13"
        try db.execute(sql: """
        INSERT INTO cost_ledger
            (id, day_key, scope, provider, model_id, status, cost_kind, cost_yuan, created_at)
        VALUES (?, '1970-01-01', 'chat', 'sentinel', 'sentinel', 'settled', 'confirmed', 0, ?)
        """, arguments: [id, now])
        let count = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM cost_ledger WHERE id = ?",
            arguments: [id]
        ) ?? 0
        guard count == 1 else {
            throw DFError.database("v13_cost_ledger 哨兵写入失败")
        }
        try db.execute(sql: "DELETE FROM cost_ledger WHERE id = ?", arguments: [id])
    }

    // MARK: - 3. schema_meta

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
            current: .v13_cost_ledger,
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
            value: MigrationID.v13_cost_ledger.rawValue,
            at: now
        )
        try SchemaMeta.write(db, key: SchemaMetaKey.appliedPhase, value: "V2-P11", at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.expectedMigrations, value: String(expected.count), at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.migratedAt, value: String(now), at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.migrationBatch, value: batch, at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.ledgerDigest, value: digest, at: now)
    }
}

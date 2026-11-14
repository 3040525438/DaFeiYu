import Foundation
import GRDB
import DFCore

/// `v4_persona` 迁移：关系档案 + 人格指纹 + 人格导入记录 + 版本快照扩展。
///
/// 边界（P3 / 决策 7、30、31）：
/// - 只做 DDL 与"新列"回填，**不修改任何历史行的既有内容**；
/// - 关系档案不凭空生成：迁移后关系三表必须为空，由真实互动与用户确认填充；
/// - 人格指纹只读 `persona_items`，不写回人格内容；
/// - 核心人格 `growth_enabled = 0`，外围人格 `growth_enabled = 1`（自主成长只作用于外围层）。
enum V4Persona {
    /// 迁移耗时上限（秒）：只有 DDL 与小表回填
    static let timeLimit: TimeInterval = 30

    /// 本迁移新增的表
    static let newTables = [
        "relationship_profile",
        "relationship_stage_history",
        "relationship_milestones",
        "persona_fingerprints",
        "persona_imports"
    ]

    /// 本迁移新增的索引
    static let newIndexes = [
        "ix_relationship_stage_time",
        "ix_relationship_stage_status",
        "ix_relationship_milestones_time",
        "ix_relationship_milestones_kind",
        "ux_persona_fingerprints",
        "ix_persona_imports_time"
    ]

    static func migrate(_ db: Database) throws {
        let startedAt = Date()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let batch = "V2-v4_persona-\(now)"

        // 0. 前置断言
        try assertUpgradable(db)

        // 1. 迁移前快照
        let personasBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM personas") ?? 0
        let itemsBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM persona_items") ?? 0
        let itemFingerprintBefore = try itemFingerprint(db)
        let tierMissingBefore = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM persona_items WHERE tier IS NULL"
        ) ?? 0
        let messagesBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? 0
        let memoriesBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM memories") ?? 0
        let previous = try previousMeta(db)

        // 2. 扩展既有表（只加列，不改历史值）
        try addPersonaColumns(db)
        try extendPersonaVersions(db)

        // 3. 新表与索引
        try createTables(db)
        try createIndexes(db)

        // 4. 新列回填 + 指纹基线
        try backfillMissingTier(db, now: now, batch: batch)
        try backfillGrowth(db)
        try computeFingerprints(db, now: now)

        // 5. 哨兵：新表可读写，随后清理
        try sentinelRoundTrip(db, now: now)

        // 6. 校验：历史内容不变、关系表为空、指纹可复算
        try validate(
            db,
            personasBefore: personasBefore,
            itemsBefore: itemsBefore,
            itemFingerprintBefore: itemFingerprintBefore,
            tierMissingBefore: tierMissingBefore,
            messagesBefore: messagesBefore,
            memoriesBefore: memoriesBefore,
            batch: batch
        )

        // 7. schema_meta
        try writeMeta(db, now: now, batch: batch, previous: previous)

        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed <= timeLimit else {
            throw DFError.database(
                String(format: "v4_persona 迁移耗时 %.1fs，超过 %.0f 秒上限", elapsed, timeLimit)
            )
        }
    }

    // MARK: - 0. 前置断言

    private static func assertUpgradable(_ db: Database) throws {
        guard let version = try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion) else {
            throw DFError.database("v4_persona 需要 schema_meta.schema_version，当前缺失")
        }
        guard version == MigrationID.v3_chat.rawValue else {
            throw DFError.database(
                "v4_persona 只能从 \(MigrationID.v3_chat.rawValue) 升级，当前为 \(version)"
            )
        }

        let quoted = newTables.map { "'\($0)'" }.joined(separator: ",")
        let existing = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN (\(quoted))"
        ) ?? 0
        guard existing == 0 else {
            throw DFError.database("v4_persona 新表已存在，不可重复执行")
        }

        guard !(try hasColumn(db, table: "personas", column: "fingerprint")) else {
            throw DFError.database("personas.fingerprint 已存在，v4_persona 不可重复执行")
        }
        guard !(try hasColumn(db, table: "persona_versions", column: "fingerprint")) else {
            throw DFError.database("persona_versions.fingerprint 已存在，v4_persona 不可重复执行")
        }
    }

    private static func hasColumn(_ db: Database, table: String, column: String) throws -> Bool {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        return try rows.contains { try $0.decode(String.self, forColumn: "name") == column }
    }

    // MARK: - 1. 快照

    /// `persona_items` 的 `(id, value)` 逐行指纹：层级与指纹计算都不得改写人格内容
    static func itemFingerprint(_ db: Database) throws -> String {
        let lines = try String.fetchAll(
            db,
            sql: "SELECT quote(id) || char(31) || quote(value) AS line FROM persona_items ORDER BY id"
        )
        return SHA256.hash(lines.joined(separator: "\u{1E}"))
    }

    /// 补齐 v2 之后新插入条目的层级（v2 只回填了迁移当时已存在的行）。
    /// 映射规则与 v2 完全一致：core → core，outer → outer，无法判定 → pending。
    /// 只写 `tier` 系列列，不触碰条目内容。
    private static func backfillMissingTier(_ db: Database, now: Int64, batch: String) throws {
        let rows = try MissingTierRow.fetchAll(
            db,
            sql: """
            SELECT i.id AS item_id, p.id AS persona_id, p.kind AS kind, p.is_locked AS is_locked
              FROM persona_items i
              LEFT JOIN personas p ON p.id = i.persona_id
             WHERE i.tier IS NULL
            """
        )

        for row in rows {
            let mapped = V2Memory.tierMapping(
                hasPersona: row.personaId != nil,
                kind: row.kind,
                isLocked: row.isLocked
            )
            try db.execute(
                sql: """
                UPDATE persona_items
                   SET tier = ?, tier_status = ?, tier_source = ?, tier_conflict = ?,
                       tier_evidence = ?, tier_migrated_at = ?, tier_batch_id = ?
                 WHERE id = ?
                """,
                arguments: [
                    mapped.tier, mapped.status, mapped.source, mapped.conflict,
                    mapped.evidence, now, batch, row.itemId
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO persona_item_tier_history
                    (id, item_id, from_tier, to_tier, from_status, to_status,
                     reason, evidence_json, decided_by, batch_id, created_at)
                VALUES (?, ?, NULL, ?, NULL, ?, 'v4_tier_repair', ?, 'migration', ?, ?)
                """,
                arguments: [
                    UUID().uuidString, row.itemId, mapped.tier, mapped.status,
                    mapped.evidence, batch, now
                ]
            )
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

    // MARK: - 2. 既有表扩展

    private static func addPersonaColumns(_ db: Database) throws {
        let statements = [
            "ALTER TABLE personas ADD COLUMN fingerprint TEXT",
            "ALTER TABLE personas ADD COLUMN fingerprint_scope TEXT NOT NULL DEFAULT 'core'",
            "ALTER TABLE personas ADD COLUMN fingerprint_at INTEGER",
            "ALTER TABLE personas ADD COLUMN growth_enabled INTEGER NOT NULL DEFAULT 0"
        ]
        for statement in statements {
            try db.execute(sql: statement)
        }
    }

    private static func extendPersonaVersions(_ db: Database) throws {
        let statements = [
            "ALTER TABLE persona_versions ADD COLUMN fingerprint TEXT",
            "ALTER TABLE persona_versions ADD COLUMN item_count INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE persona_versions ADD COLUMN parent_version INTEGER",
            "ALTER TABLE persona_versions ADD COLUMN status TEXT NOT NULL DEFAULT 'applied'"
        ]
        for statement in statements {
            try db.execute(sql: statement)
        }
    }

    // MARK: - 3. 建表

    private static func createTables(_ db: Database) throws {
        // 关系档案：单份关系的主记录，阶段变化必须留痕
        try db.execute(sql: """
        CREATE TABLE relationship_profile (
            id            TEXT PRIMARY KEY,
            partner_name  TEXT NOT NULL DEFAULT '',
            stage         TEXT NOT NULL DEFAULT 'unset',
            stage_since   INTEGER,
            closeness     REAL NOT NULL DEFAULT 0.5,
            summary       TEXT NOT NULL DEFAULT '',
            evidence_json TEXT NOT NULL DEFAULT '[]',
            confirmed_by  TEXT,
            confirmed_at  INTEGER,
            updated_at    INTEGER NOT NULL
        )
        """)

        // 阶段变更历史：模型只能提案，用户确认后才改变 stage（决策 31 / A-14）
        try db.execute(sql: """
        CREATE TABLE relationship_stage_history (
            id            TEXT PRIMARY KEY,
            from_stage    TEXT,
            to_stage      TEXT NOT NULL,
            reason        TEXT NOT NULL DEFAULT '',
            evidence_json TEXT NOT NULL DEFAULT '[]',
            decided_by    TEXT NOT NULL,
            status        TEXT NOT NULL DEFAULT 'pending',
            memory_id     TEXT REFERENCES memories(id) ON DELETE SET NULL,
            created_at    INTEGER NOT NULL,
            resolved_at   INTEGER
        )
        """)

        // 共同经历与重要转折
        try db.execute(sql: """
        CREATE TABLE relationship_milestones (
            id             TEXT PRIMARY KEY,
            kind           TEXT NOT NULL,
            title          TEXT NOT NULL,
            summary        TEXT NOT NULL DEFAULT '',
            occurred_at    INTEGER NOT NULL,
            time_precision TEXT NOT NULL DEFAULT 'day',
            importance     TEXT NOT NULL DEFAULT 'normal',
            memory_id      TEXT REFERENCES memories(id) ON DELETE SET NULL,
            episode_id     TEXT REFERENCES episodes(id) ON DELETE SET NULL,
            source_kind    TEXT NOT NULL DEFAULT 'real_interaction',
            status         TEXT NOT NULL DEFAULT 'active',
            created_at     INTEGER NOT NULL,
            updated_at     INTEGER NOT NULL
        )
        """)

        // 人格指纹基线：同一人格同一范围同一指纹只允许一行
        try db.execute(sql: """
        CREATE TABLE persona_fingerprints (
            id          TEXT PRIMARY KEY,
            persona_id  TEXT NOT NULL REFERENCES personas(id) ON DELETE CASCADE,
            scope       TEXT NOT NULL,
            algorithm   TEXT NOT NULL DEFAULT 'sha256-v1',
            fingerprint TEXT NOT NULL,
            item_count  INTEGER NOT NULL DEFAULT 0,
            computed_at INTEGER NOT NULL,
            trigger     TEXT NOT NULL DEFAULT 'launch',
            status      TEXT NOT NULL DEFAULT 'baseline'
        )
        """)

        // 人格导入记录（AstrBot / JSON / Markdown / TXT），失败必须留痕且不静默丢弃
        try db.execute(sql: """
        CREATE TABLE persona_imports (
            id            TEXT PRIMARY KEY,
            source_kind   TEXT NOT NULL,
            source_name   TEXT NOT NULL DEFAULT '',
            source_ref    TEXT NOT NULL DEFAULT '',
            source_hash   TEXT,
            item_total    INTEGER NOT NULL DEFAULT 0,
            item_imported INTEGER NOT NULL DEFAULT 0,
            item_skipped  INTEGER NOT NULL DEFAULT 0,
            status        TEXT NOT NULL DEFAULT 'pending',
            report_json   TEXT NOT NULL DEFAULT '{}',
            error         TEXT,
            started_at    INTEGER NOT NULL,
            finished_at   INTEGER
        )
        """)
    }

    private static func createIndexes(_ db: Database) throws {
        let statements = [
            "CREATE INDEX ix_relationship_stage_time ON relationship_stage_history(created_at)",
            "CREATE INDEX ix_relationship_stage_status ON relationship_stage_history(status, created_at)",
            "CREATE INDEX ix_relationship_milestones_time ON relationship_milestones(occurred_at)",
            "CREATE INDEX ix_relationship_milestones_kind ON relationship_milestones(kind, occurred_at)",
            "CREATE UNIQUE INDEX ux_persona_fingerprints ON persona_fingerprints(persona_id, scope, fingerprint)",
            "CREATE INDEX ix_persona_imports_time ON persona_imports(started_at)"
        ]
        for statement in statements {
            try db.execute(sql: statement)
        }
    }

    // MARK: - 4. 回填

    /// 只写新列：外围人格允许自主成长，核心人格永不自动改写（决策 7 / 30）
    private static func backfillGrowth(_ db: Database) throws {
        try db.execute(sql: """
        UPDATE personas SET growth_enabled = CASE WHEN kind = 'outer' THEN 1 ELSE 0 END
        """)
    }

    private static func fingerprintItems(_ db: Database, personaID: String) throws -> [PersonaFingerprint.Item] {
        try PersonaFingerprintItemRow.fetchAll(
            db,
            sql: """
            SELECT key, value, coalesce(tier, 'pending') AS tier
              FROM persona_items
             WHERE persona_id = ?
               AND status = 'active'
            """,
            arguments: [personaID]
        ).map { PersonaFingerprint.Item(key: $0.key, value: $0.value, tier: $0.tier) }
    }

    /// 为每个人格写入 `core` 与 `core_outer` 两个范围的基线指纹
    private static func computeFingerprints(_ db: Database, now: Int64) throws {
        let personaIDs = try String.fetchAll(db, sql: "SELECT id FROM personas ORDER BY id")

        for personaID in personaIDs {
            let items = try fingerprintItems(db, personaID: personaID)
            for scope in PersonaFingerprint.Scope.allCases {
                let result = PersonaFingerprint.compute(items: items, scope: scope)
                try db.execute(
                    sql: """
                    INSERT INTO persona_fingerprints
                        (id, persona_id, scope, algorithm, fingerprint, item_count, computed_at, trigger, status)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 'migration', 'baseline')
                    """,
                    arguments: [
                        UUID().uuidString,
                        personaID,
                        scope.rawValue,
                        PersonaFingerprint.algorithm,
                        result.fingerprint,
                        result.itemCount,
                        now
                    ]
                )

                if scope == .core {
                    try db.execute(
                        sql: "UPDATE personas SET fingerprint = ?, fingerprint_scope = ?, fingerprint_at = ? WHERE id = ?",
                        arguments: [result.fingerprint, scope.rawValue, now, personaID]
                    )
                }
            }
        }
    }

    // MARK: - 5. 哨兵

    /// 用一条临时人格验证 5 张新表均可写，随后全部删除；不依赖库中已有数据。
    private static func sentinelRoundTrip(_ db: Database, now: Int64) throws {
        let personaID = "__v4_sentinel_persona__"

        try db.execute(
            sql: """
            INSERT INTO personas (id, kind, name, is_locked, current_version, created_at, updated_at)
            VALUES (?, 'outer', 'v4 sentinel', 0, 1, ?, ?)
            """,
            arguments: [personaID, now, now]
        )
        try db.execute(
            sql: """
            INSERT INTO relationship_profile (id, partner_name, stage, updated_at)
            VALUES ('__v4_sentinel_profile__', 'sentinel', 'unset', ?)
            """,
            arguments: [now]
        )
        try db.execute(
            sql: """
            INSERT INTO relationship_stage_history (id, from_stage, to_stage, decided_by, created_at)
            VALUES ('__v4_sentinel_stage__', NULL, 'sentinel', 'migration', ?)
            """,
            arguments: [now]
        )
        try db.execute(
            sql: """
            INSERT INTO relationship_milestones (id, kind, title, occurred_at, created_at, updated_at)
            VALUES ('__v4_sentinel_milestone__', 'sentinel', 'sentinel', ?, ?, ?)
            """,
            arguments: [now, now, now]
        )
        try db.execute(
            sql: """
            INSERT INTO persona_fingerprints (id, persona_id, scope, fingerprint, computed_at)
            VALUES ('__v4_sentinel_fingerprint__', ?, 'core', 'sentinel', ?)
            """,
            arguments: [personaID, now]
        )
        try db.execute(
            sql: """
            INSERT INTO persona_imports (id, source_kind, status, started_at)
            VALUES ('__v4_sentinel_import__', 'sentinel', 'pending', ?)
            """,
            arguments: [now]
        )

        let written = try Int.fetchOne(
            db,
            sql: """
            SELECT (SELECT count(*) FROM relationship_profile) +
                   (SELECT count(*) FROM relationship_stage_history) +
                   (SELECT count(*) FROM relationship_milestones) +
                   (SELECT count(*) FROM persona_fingerprints) +
                   (SELECT count(*) FROM persona_imports)
            """
        ) ?? 0

        try db.execute(sql: "DELETE FROM persona_imports WHERE id = '__v4_sentinel_import__'")
        try db.execute(sql: "DELETE FROM persona_fingerprints WHERE id = '__v4_sentinel_fingerprint__'")
        try db.execute(sql: "DELETE FROM relationship_milestones WHERE id = '__v4_sentinel_milestone__'")
        try db.execute(sql: "DELETE FROM relationship_stage_history WHERE id = '__v4_sentinel_stage__'")
        try db.execute(sql: "DELETE FROM relationship_profile WHERE id = '__v4_sentinel_profile__'")
        try db.execute(sql: "DELETE FROM personas WHERE id = ?", arguments: [personaID])

        guard written >= 5 else {
            throw DFError.database("v4_persona 哨兵写入失败：新表不可写")
        }
    }

    // MARK: - 6. 校验

    private static func validate(
        _ db: Database,
        personasBefore: Int,
        itemsBefore: Int,
        itemFingerprintBefore: String,
        tierMissingBefore: Int,
        messagesBefore: Int,
        memoriesBefore: Int,
        batch: String
    ) throws {
        let personasAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM personas") ?? -1
        guard personasAfter == personasBefore else {
            throw DFError.database("v4_persona 改变了人格行数：\(personasBefore) → \(personasAfter)")
        }

        let itemsAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM persona_items") ?? -1
        guard itemsAfter == itemsBefore else {
            throw DFError.database("v4_persona 改变了人格条目行数：\(itemsBefore) → \(itemsAfter)")
        }
        let itemFingerprintAfter = try itemFingerprint(db)
        guard itemFingerprintAfter == itemFingerprintBefore else {
            throw DFError.database("v4_persona 改写了人格条目内容，迁移被拒绝")
        }

        // 层级只有"从 NULL 补齐"，不允许改动已有取值
        let tierMissingAfter = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM persona_items WHERE tier IS NULL"
        ) ?? -1
        guard tierMissingAfter == 0 else {
            throw DFError.database("仍有 \(tierMissingAfter) 条人格条目缺少层级")
        }
        let repaired = try Int.fetchOne(
            db,
            sql: """
            SELECT count(*) FROM persona_item_tier_history
             WHERE batch_id = ? AND reason = 'v4_tier_repair'
            """,
            arguments: [batch]
        ) ?? -1
        guard repaired == tierMissingBefore else {
            throw DFError.database("层级补齐记录数异常：期望 \(tierMissingBefore)，实际 \(repaired)")
        }

        let messagesAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? -1
        guard messagesAfter == messagesBefore else {
            throw DFError.database("v4_persona 改变了消息行数：\(messagesBefore) → \(messagesAfter)")
        }
        let memoriesAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM memories") ?? -1
        guard memoriesAfter == memoriesBefore else {
            throw DFError.database("v4_persona 改变了记忆行数：\(memoriesBefore) → \(memoriesAfter)")
        }

        // 关系档案不得凭空生成（禁止把推断写成真实经历）
        for table in ["relationship_profile", "relationship_stage_history", "relationship_milestones"] {
            let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? -1
            guard count == 0 else {
                throw DFError.database("v4_persona 不得回填关系数据：\(table) 有 \(count) 行")
            }
        }

        // 指纹：每个人格每个范围各一行，且必须能独立复算
        let scopes = PersonaFingerprint.Scope.allCases
        let expectedRows = personasAfter * scopes.count
        let fingerprintRows = try Int.fetchOne(db, sql: "SELECT count(*) FROM persona_fingerprints") ?? -1
        guard fingerprintRows == expectedRows else {
            throw DFError.database("人格指纹行数异常：期望 \(expectedRows)，实际 \(fingerprintRows)")
        }

        let rows = try PersonaFingerprintRow.fetchAll(
            db,
            sql: "SELECT persona_id, scope, fingerprint FROM persona_fingerprints"
        )
        for row in rows {
            guard let scope = PersonaFingerprint.Scope(rawValue: row.scope) else {
                throw DFError.database("未知的人格指纹范围：\(row.scope)")
            }
            let items = try fingerprintItems(db, personaID: row.personaId)
            guard PersonaFingerprint.compute(items: items, scope: scope).fingerprint == row.fingerprint else {
                throw DFError.database("人格指纹不可复算：persona=\(row.personaId) scope=\(row.scope)")
            }
        }

        let missing = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM personas WHERE fingerprint IS NULL"
        ) ?? -1
        guard missing == 0 else {
            throw DFError.database("有 \(missing) 个人格缺少指纹基线")
        }

        // 核心人格不得自主成长
        let growingCore = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM personas WHERE kind = 'core' AND growth_enabled <> 0"
        ) ?? -1
        guard growingCore == 0 else {
            throw DFError.database("核心人格被错误开启自主成长：\(growingCore) 行")
        }

        let quick = try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "unknown"
        guard quick.lowercased() == "ok" else {
            throw DFError.database("v4_persona 迁移后 quick_check 失败：\(quick)")
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
        let expected = try SchemaMeta.expectedPrefixIncluding(current: .v4_persona, appliedBefore: appliedBefore)
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

        try SchemaMeta.write(db, key: SchemaMetaKey.schemaVersion, value: MigrationID.v4_persona.rawValue, at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.appliedPhase, value: "V2-P3", at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.expectedMigrations, value: String(expected.count), at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.migratedAt, value: String(now), at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.migrationBatch, value: batch, at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.ledgerDigest, value: digest, at: now)
    }
}

// MARK: - 内部查询模型

private struct PersonaFingerprintItemRow: Decodable, FetchableRecord {
    var key: String
    var value: String
    var tier: String
}

private struct MissingTierRow: Decodable, FetchableRecord {
    var itemId: String
    var personaId: String?
    var kind: String?
    var isLocked: Int?

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case personaId = "persona_id"
        case kind
        case isLocked = "is_locked"
    }
}

private struct PersonaFingerprintRow: Decodable, FetchableRecord {
    var personaId: String
    var scope: String
    var fingerprint: String

    enum CodingKeys: String, CodingKey {
        case personaId = "persona_id"
        case scope
        case fingerprint
    }
}

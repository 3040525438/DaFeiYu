import XCTest
import GRDB
import DFCore
@testable import DFData

/// v4_persona 迁移测试（V4-01 ~ V4-10）
final class MigrationV4Tests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFV4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - 辅助

    private func makeQueue(_ name: String, upTo last: MigrationID) throws -> DatabaseQueue {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: dir.appendingPathComponent("db.sqlite").path)
        try Migrations.makeMigrator(upTo: last).migrate(queue)
        return queue
    }

    private func makeDatabase(_ name: String) throws -> AppDatabase {
        // v5_autonomy 发布后，生产入口已包到 v5；本文件必须锁定在 v4 才能验证 v4 自身的门禁与摘要
        try AppDatabase(
            paths: DatabasePaths(root: root.appendingPathComponent(name, isDirectory: true)),
            makeMigrator: { Migrations.makeMigrator(upTo: .v4_persona) }
        )
    }

    /// 构造 v3 库：1 个核心人格 + 1 个外围人格 + 2 条**未标层级**的条目 + 1 条记忆
    private func seedV3(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO personas (id, kind, name, is_locked, current_version, created_at, updated_at)
            VALUES ('p-core', 'core', '大肥鱼', 1, 1, 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO personas (id, kind, name, is_locked, current_version, created_at, updated_at)
            VALUES ('p-outer', 'outer', '大肥鱼·成长', 0, 1, 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO persona_items (id, persona_id, section, key, value, source, updated_at)
            VALUES ('i-core', 'p-core', '核心', 'system_prompt', '我是大肥鱼。', 'user', 1)
            """)
            try db.execute(sql: """
            INSERT INTO persona_items (id, persona_id, section, key, value, source, updated_at)
            VALUES ('i-outer', 'p-outer', '兴趣', 'interest', '摄影', 'model', 2)
            """)
            try db.execute(sql: """
            INSERT INTO memories (id, type, title, content, importance, first_seen_at)
            VALUES ('mem1', 'fact', '摄影', '她喜欢摄影', 'high', 1)
            """)
        }
    }

    private func itemLines(_ db: Database) throws -> [String] {
        try String.fetchAll(
            db,
            sql: "SELECT quote(id) || '|' || quote(value) FROM persona_items ORDER BY id"
        )
    }

    private func fingerprintItems(_ db: Database, personaID: String) throws -> [PersonaFingerprint.Item] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT key, value, coalesce(tier, 'pending') AS tier
              FROM persona_items
             WHERE persona_id = ? AND status = 'active'
            """,
            arguments: [personaID]
        ).map {
            PersonaFingerprint.Item(
                key: try $0.decode(String.self, forColumn: "key"),
                value: try $0.decode(String.self, forColumn: "value"),
                tier: try $0.decode(String.self, forColumn: "tier")
            )
        }
    }

    // MARK: - V4-01 全新库 v1 → v4

    func testV401_FreshV1DatabaseMigratesToV4() throws {
        let queue = try makeQueue("v401", upTo: .v1_phase1)
        try Migrations.makeMigrator(upTo: .v4_persona).migrate(queue)

        try queue.read { db in
            let ledger = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            XCTAssertEqual(Set(ledger), ["v1_phase1", "v2_memory", "v3_chat", "v4_persona"])
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion), "v4_persona")
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.expectedMigrations), "4")

            let quoted = V4Persona.newTables.map { "'\($0)'" }.joined(separator: ",")
            let tables = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name IN (\(quoted))"
            )
            XCTAssertEqual(Set(tables), Set(V4Persona.newTables))
            try SchemaMeta.verifyRequiredObjects(db, upTo: .v4_persona)
        }
    }

    // MARK: - V4-02 v3 → v4 保留历史数据并补齐层级

    func testV402_IncrementalFromV3KeepsData() throws {
        let queue = try makeQueue("v402", upTo: .v3_chat)
        try seedV3(queue)

        let itemsBefore = try queue.read { db in try itemLines(db) }
        let personasBefore = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM personas") ?? -1
        }

        try Migrations.makeMigrator(upTo: .v4_persona).migrate(queue)

        try queue.read { db in
            XCTAssertEqual(try itemLines(db), itemsBefore, "人格条目内容必须逐字不变")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM personas"), personasBefore)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM memories"), 1)

            // 两条条目在 v2 之后插入，tier 为 NULL，由 v4 补齐
            let tiers = try String.fetchAll(
                db,
                sql: "SELECT id || ':' || tier FROM persona_items ORDER BY id"
            )
            XCTAssertEqual(tiers, ["i-core:core", "i-outer:outer"])
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM persona_item_tier_history WHERE reason = 'v4_tier_repair'"
                ),
                2
            )
        }
    }

    // MARK: - V4-03 重复执行保护

    func testV403_RepeatedV4Rejected() throws {
        let queue = try makeQueue("v403", upTo: .v3_chat)
        try seedV3(queue)
        try Migrations.makeMigrator(upTo: .v4_persona).migrate(queue)

        let before = try queue.read { db in try itemLines(db) }
        XCTAssertThrowsError(try queue.write { db in try V4Persona.migrate(db) })

        try queue.read { db in
            XCTAssertEqual(try itemLines(db), before)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM grdb_migrations"), 4)
        }
    }

    // MARK: - V4-04 关系档案不得凭空生成

    func testV404_RelationshipTablesStayEmpty() throws {
        let queue = try makeQueue("v404", upTo: .v3_chat)
        try seedV3(queue)
        try Migrations.makeMigrator(upTo: .v4_persona).migrate(queue)

        try queue.read { db in
            for table in ["relationship_profile", "relationship_stage_history", "relationship_milestones"] {
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)"), 0, "\(table) 不得回填")
            }
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM persona_imports"), 0)
        }
    }

    // MARK: - V4-05 自主成长开关

    func testV405_GrowthOnlyForOuterPersona() throws {
        let queue = try makeQueue("v405", upTo: .v3_chat)
        try seedV3(queue)
        try Migrations.makeMigrator(upTo: .v4_persona).migrate(queue)

        try queue.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT growth_enabled FROM personas WHERE id = 'p-core'"),
                0,
                "核心人格不得自动改写"
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT growth_enabled FROM personas WHERE id = 'p-outer'"),
                1,
                "外围人格允许自主成长"
            )
        }
    }

    // MARK: - V4-06 指纹基线与独立复算

    func testV406_FingerprintBaselineIsRecomputable() throws {
        let queue = try makeQueue("v406", upTo: .v3_chat)
        try seedV3(queue)
        try Migrations.makeMigrator(upTo: .v4_persona).migrate(queue)

        try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT persona_id, scope, fingerprint FROM persona_fingerprints ORDER BY persona_id, scope"
            )
            XCTAssertEqual(rows.count, 4, "2 个人格 × 2 个范围")

            for row in rows {
                let personaID = try row.decode(String.self, forColumn: "persona_id")
                let scope = try row.decode(String.self, forColumn: "scope")
                let stored = try row.decode(String.self, forColumn: "fingerprint")
                let parsed = try XCTUnwrap(PersonaFingerprint.Scope(rawValue: scope))
                let items = try fingerprintItems(db, personaID: personaID)
                XCTAssertEqual(
                    PersonaFingerprint.compute(items: items, scope: parsed).fingerprint,
                    stored,
                    "指纹必须可由条目独立复算"
                )
            }

            // 核心指纹不包含外围条目：新增外围条目后 core 不变、core_outer 改变
            let coreItems = try fingerprintItems(db, personaID: "p-core")
            let coreBefore = PersonaFingerprint.compute(items: coreItems, scope: .core).fingerprint
            var withOuter = coreItems
            withOuter.append(PersonaFingerprint.Item(key: "interest", value: "摄影", tier: "outer"))
            XCTAssertEqual(
                PersonaFingerprint.compute(items: withOuter, scope: .core).fingerprint,
                coreBefore
            )
            XCTAssertNotEqual(
                PersonaFingerprint.compute(items: withOuter, scope: .coreOuter).fingerprint,
                PersonaFingerprint.compute(items: coreItems, scope: .coreOuter).fingerprint
            )

            // personas.fingerprint 记录核心范围基线
            let personaCore = try String.fetchOne(
                db,
                sql: "SELECT fingerprint FROM personas WHERE id = 'p-core'"
            )
            XCTAssertEqual(personaCore, coreBefore)
        }
    }

    // MARK: - V4-07 必需对象门禁（27 项）

    func testV407_RequiredObjectsCountTwentySeven() throws {
        let database = try makeDatabase("v407")

        try database.dbQueue.read { db in
            try SchemaMeta.verifyRequiredObjects(db, upTo: .v4_persona)

            let names = V4Persona.newTables + V4Persona.newIndexes
            let quoted = names.map { "'\($0)'" }.joined(separator: ",")
            let found = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE name IN (\(quoted))"
            )
            XCTAssertEqual(Set(found), Set(names))

            let index = try Row.fetchOne(
                db,
                sql: "SELECT * FROM pragma_index_list('persona_fingerprints') WHERE name = 'ux_persona_fingerprints'"
            )
            XCTAssertEqual(try index?.decode(Bool.self, forColumn: "unique"), true)
        }
    }

    // MARK: - V4-08 台账摘要独立复算

    func testV408_LedgerDigestRecomputedIndependently() throws {
        let database = try makeDatabase("v408")

        try database.dbQueue.read { db in
            let canonical = ["v1_phase1", "v2_memory", "v3_chat", "v4_persona"]
            let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            XCTAssertEqual(Set(applied), Set(canonical))
            XCTAssertEqual(
                try SchemaMeta.value(db, key: SchemaMetaKey.ledgerDigest),
                SHA256.hash("migrations-v1\n" + canonical.joined(separator: "\n"))
            )
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion), canonical.last)
        }
    }

    // MARK: - V4-09 previous_* 保留 v3 原值

    func testV409_PreviousKeysPreserveV3Values() throws {
        let queue = try makeQueue("v409", upTo: .v3_chat)
        try seedV3(queue)

        let previous = try queue.read { db in
            (
                try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion),
                try SchemaMeta.value(db, key: SchemaMetaKey.migrationBatch),
                try SchemaMeta.value(db, key: SchemaMetaKey.migratedAt)
            )
        }
        XCTAssertEqual(previous.0, "v3_chat")

        try Migrations.makeMigrator(upTo: .v4_persona).migrate(queue)

        try queue.read { db in
            XCTAssertEqual(
                try SchemaMeta.value(db, key: SchemaMetaKey.previousSchemaVersion),
                previous.0
            )
            XCTAssertEqual(
                try SchemaMeta.value(db, key: SchemaMetaKey.previousMigrationBatch),
                previous.1
            )
            XCTAssertEqual(
                try SchemaMeta.value(db, key: SchemaMetaKey.previousMigratedAt),
                previous.2
            )
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion), "v4_persona")
        }
    }

    // MARK: - V4-10 哨兵不留残留

    func testV410_SentinelLeavesNoResidue() throws {
        let queue = try makeQueue("v410", upTo: .v3_chat)
        try seedV3(queue)
        try Migrations.makeMigrator(upTo: .v4_persona).migrate(queue)

        try queue.read { db in
            let sentinels = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM personas WHERE id LIKE '__v4_sentinel%'"
            )
            XCTAssertEqual(sentinels, 0)

            let fingerprints = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM persona_fingerprints WHERE id LIKE '__v4_sentinel%'"
            )
            XCTAssertEqual(fingerprints, 0)

            let profile = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM relationship_profile WHERE id LIKE '__v4_sentinel%'"
            )
            XCTAssertEqual(profile, 0)

            let stage = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM relationship_stage_history WHERE id LIKE '__v4_sentinel%'"
            )
            XCTAssertEqual(stage, 0)

            let milestone = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM relationship_milestones WHERE id LIKE '__v4_sentinel%'"
            )
            XCTAssertEqual(milestone, 0)

            let imports = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM persona_imports WHERE id LIKE '__v4_sentinel%'"
            )
            XCTAssertEqual(imports, 0)
        }
    }
}

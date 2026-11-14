import XCTest
import GRDB
import DFCore
@testable import DFData

/// v9_astrbot 迁移测试（V9-01 ~ V9-10）
final class MigrationV9Tests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFV9-\(UUID().uuidString)", isDirectory: true)
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
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(
            path: dir.appendingPathComponent("db.sqlite").path,
            configuration: configuration
        )
        try Migrations.makeMigrator(upTo: last).migrate(queue)
        return queue
    }

    private func makeDatabase(_ name: String) throws -> AppDatabase {
        try AppDatabase(paths: DatabasePaths(root: root.appendingPathComponent(name, isDirectory: true)))
    }

    /// 构造 v8 库：会话/消息/记忆/人格条目各一条
    private func seedV8(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '大肥鱼', 'main', 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
            VALUES ('m1', 'uuid-m1', 'c1', 'user', 'text', '晚安', 'sent', 'user', 2)
            """)
            try db.execute(sql: """
            INSERT INTO memories (id, type, title, content, importance, first_seen_at)
            VALUES ('mem1', 'fact', '作息', '她常熬夜', 'normal', 1)
            """)
            try db.execute(sql: """
            INSERT INTO personas (id, kind, name, is_locked, current_version, created_at, updated_at)
            VALUES ('p-core', 'core', '大肥鱼', 1, 1, 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO persona_items (id, persona_id, section, key, value, source, updated_at)
            VALUES ('i-core', 'p-core', '核心', 'system_prompt', '我是大肥鱼。', 'user', 1)
            """)
        }
    }

    private func objectNames(_ db: Database, names: [String]) throws -> Set<String> {
        let quoted = names.map { "'\($0)'" }.joined(separator: ",")
        let found = try String.fetchAll(
            db,
            sql: "SELECT name FROM sqlite_master WHERE name IN (\(quoted))"
        )
        return Set(found)
    }

    // MARK: - V9-01 全新库 v1 → v9

    func testV901_FreshV1DatabaseMigratesToV9() throws {
        let queue = try makeQueue("v901", upTo: .v1_phase1)
        // 锁定 v9：生产 migrator 会随新版本前移，本用例只验证 v9 自身
        try Migrations.makeMigrator(upTo: .v9_astrbot).migrate(queue)

        try queue.read { db in
            let ledger = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            XCTAssertEqual(ledger.count, 9)
            XCTAssertEqual(Set(ledger), Set(MigrationLedger.expectedPrefix(count: 9)))
            XCTAssertEqual(
                try MigrationLedger.validatedPrefix(applied: ledger).last,
                MigrationID.v9_astrbot.rawValue
            )
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion), "v9_astrbot")
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.expectedMigrations), "9")
            XCTAssertEqual(try objectNames(db, names: V9AstrBot.newTables), Set(V9AstrBot.newTables))
            try SchemaMeta.verifyRequiredObjects(db, upTo: .v9_astrbot)
        }
    }

    // MARK: - V9-02 v8 → v9 保留历史数据

    func testV902_IncrementalFromV8KeepsData() throws {
        let queue = try makeQueue("v902", upTo: .v8_chat_v2)
        try seedV8(queue)

        let snapshot = try queue.read { db in
            (
                try V3Chat.messageFingerprint(db),
                try V4Persona.itemFingerprint(db)
            )
        }

        try Migrations.makeMigrator(upTo: .v9_astrbot).migrate(queue)

        try queue.read { db in
            XCTAssertEqual(try V3Chat.messageFingerprint(db), snapshot.0, "历史消息必须逐字不变")
            XCTAssertEqual(try V4Persona.itemFingerprint(db), snapshot.1, "人格条目必须逐字不变")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM messages"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM memories"), 1)
        }
    }

    // MARK: - V9-03 重复执行保护

    func testV903_RepeatedV9Rejected() throws {
        let queue = try makeQueue("v903", upTo: .v8_chat_v2)
        try seedV8(queue)
        try Migrations.makeMigrator(upTo: .v9_astrbot).migrate(queue)

        XCTAssertThrowsError(try queue.write { db in try V9AstrBot.migrate(db) })

        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM grdb_migrations"), 9)
        }
    }

    // MARK: - V9-04 迁移表不得预置（迁移必须由真实导入驱动）

    func testV904_AstrBotTablesStayEmpty() throws {
        let queue = try makeQueue("v904", upTo: .v8_chat_v2)
        try seedV8(queue)
        try Migrations.makeMigrator(upTo: .v9_astrbot).migrate(queue)

        try queue.read { db in
            for table in V9AstrBot.newTables {
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)"),
                    0,
                    "\(table) 不得预置数据：迁移必须由真实导入驱动"
                )
            }
        }
    }

    // MARK: - V9-05 原始 ID 映射唯一

    func testV905_IdMapIsUniquePerBatch() throws {
        let queue = try makeQueue("v905", upTo: .v8_chat_v2)
        try seedV8(queue)
        try Migrations.makeMigrator(upTo: .v9_astrbot).migrate(queue)

        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO astrbot_migration_batches (id, source_kind, source_ref, started_at)
            VALUES ('b1', 'astrbot', 'workcopy', 1)
            """)
            try db.execute(sql: """
            INSERT INTO astrbot_id_map (id, batch_id, entity_kind, source_id, target_id, created_at)
            VALUES ('map1', 'b1', 'message', 'src-1', 'm1', 2)
            """)
        }

        // 同一批次内同一实体同一原始 ID 不得重复映射
        XCTAssertThrowsError(
            try queue.write { db in
                try db.execute(sql: """
                INSERT INTO astrbot_id_map (id, batch_id, entity_kind, source_id, target_id, created_at)
                VALUES ('map2', 'b1', 'message', 'src-1', 'm2', 3)
                """)
            }
        )

        // 不同批次允许重复映射（便于重跑对比）
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO astrbot_migration_batches (id, source_kind, source_ref, started_at)
            VALUES ('b2', 'astrbot', 'workcopy', 4)
            """)
            try db.execute(sql: """
            INSERT INTO astrbot_id_map (id, batch_id, entity_kind, source_id, target_id, created_at)
            VALUES ('map3', 'b2', 'message', 'src-1', 'm1', 5)
            """)
        }
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM astrbot_id_map"), 2)
        }
    }

    // MARK: - V9-06 删除批次级联清理映射与待处理区

    func testV906_BatchDeletionCascades() throws {
        let queue = try makeQueue("v906", upTo: .v8_chat_v2)
        try seedV8(queue)
        try Migrations.makeMigrator(upTo: .v9_astrbot).migrate(queue)

        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO astrbot_migration_batches (id, source_kind, source_ref, started_at)
            VALUES ('b1', 'astrbot', 'workcopy', 1)
            """)
            try db.execute(sql: """
            INSERT INTO astrbot_id_map (id, batch_id, entity_kind, source_id, target_id, created_at)
            VALUES ('map1', 'b1', 'memory', 'src-1', 'mem1', 2)
            """)
            try db.execute(sql: """
            INSERT INTO astrbot_import_pending
                (id, batch_id, entity_kind, reason_code, raw_json, created_at)
            VALUES ('p1', 'b1', 'memory', 'unrecognized', '{}', 3)
            """)
            try db.execute(sql: "DELETE FROM astrbot_migration_batches WHERE id = 'b1'")
        }

        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM astrbot_id_map"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM astrbot_import_pending"), 0)
            // 目标数据不受影响
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM memories"), 1)
        }
    }

    // MARK: - V9-07 必需对象门禁（81 项）

    func testV907_RequiredObjectsCountEightyOne() throws {
        let database = try makeDatabase("v907")

        try database.dbQueue.read { db in
            try SchemaMeta.verifyRequiredObjects(db)

            let names = V9AstrBot.newTables + V9AstrBot.newIndexes
            XCTAssertEqual(try objectNames(db, names: names), Set(names))
        }
    }

    // MARK: - V9-08 previous_* 保留 v8 原值

    func testV908_PreviousKeysPreserveV8Values() throws {
        let queue = try makeQueue("v908", upTo: .v8_chat_v2)
        try seedV8(queue)

        let previous = try queue.read { db in
            (
                try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion),
                try SchemaMeta.value(db, key: SchemaMetaKey.migrationBatch),
                try SchemaMeta.value(db, key: SchemaMetaKey.migratedAt)
            )
        }
        XCTAssertEqual(previous.0, "v8_chat_v2")

        try Migrations.makeMigrator(upTo: .v9_astrbot).migrate(queue)

        try queue.read { db in
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.previousSchemaVersion), previous.0)
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.previousMigrationBatch), previous.1)
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.previousMigratedAt), previous.2)
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion), "v9_astrbot")
        }
    }

    // MARK: - V9-09 台账摘要独立复算

    func testV909_LedgerDigestRecomputedIndependently() throws {
        // 锁定 v9：生产 migrator 已前移到 v11，本用例只验 v9 自己的台账
        let queue = try makeQueue("v909", upTo: .v9_astrbot)

        try queue.read { db in
            let expected = MigrationLedger.expectedPrefix(count: 9)
            let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            XCTAssertEqual(Set(applied), Set(expected))
            XCTAssertEqual(
                try SchemaMeta.value(db, key: SchemaMetaKey.ledgerDigest),
                SHA256.hash("migrations-v1\n" + expected.joined(separator: "\n"))
            )
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.appliedPhase), "V2-P8")
        }
    }

    // MARK: - V9-10 哨兵不留残留

    func testV910_SentinelLeavesNoResidue() throws {
        let queue = try makeQueue("v910", upTo: .v8_chat_v2)
        try seedV8(queue)
        try Migrations.makeMigrator(upTo: .v9_astrbot).migrate(queue)

        try queue.read { db in
            for table in V9AstrBot.newTables {
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table) WHERE id LIKE '__v9_sentinel%'"),
                    0,
                    "\(table) 不得残留哨兵数据"
                )
            }
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA quick_check"), "ok")
        }
    }
}

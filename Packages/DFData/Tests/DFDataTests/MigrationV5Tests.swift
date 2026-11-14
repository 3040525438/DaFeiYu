import XCTest
import GRDB
import DFCore
@testable import DFData

/// v5_autonomy 迁移测试（V5-01 ~ V5-10）
final class MigrationV5Tests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFV5-\(UUID().uuidString)", isDirectory: true)
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
        // 与 AppDatabase 一致：每个连接都开启外键，级联与引用约束才真正生效
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

    /// 构造 v4 库：1 个会话 + 1 条消息 + 1 条记忆 + 1 个人格与其条目
    private func seedV4(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '大肥鱼', 'main', 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
            VALUES ('m1', 'uuid-m1', 'c1', 'user', 'text', '今天去看了摄影展', 'sent', 'user', 2)
            """)
            try db.execute(sql: """
            INSERT INTO memories (id, type, title, content, importance, first_seen_at)
            VALUES ('mem1', 'fact', '摄影', '她喜欢摄影', 'high', 1)
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

    // MARK: - V5-01 全新库 v1 → v5

    func testV501_FreshV1DatabaseMigratesToV5() throws {
        let queue = try makeQueue("v501", upTo: .v1_phase1)
        try Migrations.makeMigrator(upTo: .v5_autonomy).migrate(queue)

        try queue.read { db in
            let ledger = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            XCTAssertEqual(Set(ledger), Set(MigrationLedger.expectedPrefix(count: 5)))
            XCTAssertEqual(
                try MigrationLedger.validatedPrefix(applied: ledger).last,
                MigrationID.v5_autonomy.rawValue
            )
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion), "v5_autonomy")
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.expectedMigrations), "5")
            XCTAssertEqual(
                try objectNames(db, names: V5Autonomy.newTables),
                Set(V5Autonomy.newTables)
            )
            try SchemaMeta.verifyRequiredObjects(db)
        }
    }

    // MARK: - V5-02 v4 → v5 保留历史数据

    func testV502_IncrementalFromV4KeepsData() throws {
        let queue = try makeQueue("v502", upTo: .v4_persona)
        try seedV4(queue)

        let snapshot = try queue.read { db in
            (
                try String.fetchAll(db, sql: "SELECT id FROM conversations ORDER BY id"),
                try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? -1,
                try V3Chat.messageFingerprint(db),
                try V4Persona.itemFingerprint(db)
            )
        }

        try Migrations.makeMigrator(upTo: .v5_autonomy).migrate(queue)

        try queue.read { db in
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT id FROM conversations ORDER BY id"), snapshot.0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM messages"), snapshot.1)
            XCTAssertEqual(try V3Chat.messageFingerprint(db), snapshot.2, "历史消息必须逐字不变")
            XCTAssertEqual(try V4Persona.itemFingerprint(db), snapshot.3, "人格条目必须逐字不变")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM memories"), 1)
        }
    }

    // MARK: - V5-03 重复执行保护

    func testV503_RepeatedV5Rejected() throws {
        let queue = try makeQueue("v503", upTo: .v4_persona)
        try seedV4(queue)
        try Migrations.makeMigrator(upTo: .v5_autonomy).migrate(queue)

        XCTAssertThrowsError(try queue.write { db in try V5Autonomy.migrate(db) })

        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM grdb_migrations"), 5)
            XCTAssertEqual(
                try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion),
                MigrationID.v5_autonomy.rawValue
            )
        }
    }

    // MARK: - V5-04 自主相关表不得预置数据

    func testV504_AutonomyTablesStayEmpty() throws {
        let queue = try makeQueue("v504", upTo: .v4_persona)
        try seedV4(queue)
        try Migrations.makeMigrator(upTo: .v5_autonomy).migrate(queue)

        try queue.read { db in
            for table in V5Autonomy.newTables {
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)"),
                    0,
                    "\(table) 不得预置数据：未开启即不主动"
                )
            }
        }
    }

    // MARK: - V5-05 历史会话的新列默认值

    func testV505_ConversationColumnsDefaultForHistory() throws {
        let queue = try makeQueue("v505", upTo: .v4_persona)
        try seedV4(queue)
        try Migrations.makeMigrator(upTo: .v5_autonomy).migrate(queue)

        try queue.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM conversations WHERE pinned_at IS NULL AND last_read_at IS NULL"
                ),
                1,
                "历史会话不得被推断成已置顶或已读"
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM conversations WHERE unread_count = 0 AND sort_index = 0"
                ),
                1
            )

            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(conversations)").map {
                try $0.decode(String.self, forColumn: "name")
            }
            XCTAssertEqual(columns.count, V5Autonomy.legacyConversationColumns.count + 4)
            XCTAssertEqual(
                Array(columns.suffix(4)),
                ["pinned_at", "sort_index", "unread_count", "last_read_at"]
            )
        }
    }

    // MARK: - V5-06 库层约束：去重键唯一、一问一对组、级联

    func testV506_AutonomyConstraintsEnforced() throws {
        let queue = try makeQueue("v506", upTo: .v4_persona)
        try seedV4(queue)

        try Migrations.makeMigrator(upTo: .v5_autonomy).migrate(queue)

        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO conversation_topics
                (id, conversation_id, title, opened_at, last_touched_at, created_at, updated_at)
            VALUES ('t1', 'c1', '摄影', 10, 10, 10, 10)
            """)
            try db.execute(sql: """
            INSERT INTO autonomy_tasks
                (id, kind, conversation_id, topic_id, dedupe_key, scheduled_at, created_at, updated_at)
            VALUES ('task1', 'followup', 'c1', 't1', 'photo|followup|1', 10, 10, 10)
            """)
        }

        // dedupe_key 重复必须被拒绝
        XCTAssertThrowsError(
            try queue.write { db in
                try db.execute(sql: """
                INSERT INTO autonomy_tasks
                    (id, kind, conversation_id, topic_id, dedupe_key, scheduled_at, created_at, updated_at)
                VALUES ('task2', 'followup', 'c1', 't1', 'photo|followup|1', 20, 20, 20)
                """)
            }
        )

        // 一个消息组最多绑定一个意图
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO message_groups (id, conversation_id, turn_index, kind, status, opened_at)
            VALUES ('g1', 'c1', 1, 'chat', 'open', 10)
            """)
            try db.execute(sql: """
            INSERT INTO conversation_intents (id, conversation_id, topic_id, group_id, planned_at, created_at)
            VALUES ('intent1', 'c1', 't1', 'g1', 10, 10)
            """)
        }
        XCTAssertThrowsError(
            try queue.write { db in
                try db.execute(sql: """
                INSERT INTO conversation_intents (id, conversation_id, topic_id, group_id, planned_at, created_at)
                VALUES ('intent2', 'c1', 't1', 'g1', 20, 20)
                """)
            }
        )

        // 删除会话必须级联清掉话题、意图、任务
        try queue.write { db in
            try db.execute(sql: "DELETE FROM conversations WHERE id = 'c1'")
        }
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM conversation_topics"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM conversation_intents"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM autonomy_tasks"), 0)
        }
    }

    // MARK: - V5-07 必需对象门禁（43 项）

    func testV507_RequiredObjectsCountFortyThree() throws {
        let database = try makeDatabase("v507")

        try database.dbQueue.read { db in
            try SchemaMeta.verifyRequiredObjects(db)

            let names = V5Autonomy.newTables + V5Autonomy.newIndexes
            XCTAssertEqual(try objectNames(db, names: names), Set(names))

            let index = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM pragma_index_list('autonomy_tasks') WHERE name = 'ux_autonomy_tasks_dedupe'
                """
            )
            XCTAssertEqual(try index?.decode(Bool.self, forColumn: "unique"), true)

            let partial = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM pragma_index_list('conversation_intents')
                 WHERE name = 'ux_conversation_intents_group'
                """
            )
            XCTAssertEqual(try partial?.decode(Bool.self, forColumn: "unique"), true)
            XCTAssertEqual(try partial?.decode(Bool.self, forColumn: "partial"), true)
        }
    }

    // MARK: - V5-08 previous_* 保留 v4 原值

    func testV508_PreviousKeysPreserveV4Values() throws {
        let queue = try makeQueue("v508", upTo: .v4_persona)
        try seedV4(queue)

        let previous = try queue.read { db in
            (
                try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion),
                try SchemaMeta.value(db, key: SchemaMetaKey.migrationBatch),
                try SchemaMeta.value(db, key: SchemaMetaKey.migratedAt)
            )
        }
        XCTAssertEqual(previous.0, "v4_persona")

        try Migrations.makeMigrator(upTo: .v5_autonomy).migrate(queue)

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
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion), "v5_autonomy")
        }
    }

    // MARK: - V5-09 台账摘要独立复算

    func testV509_LedgerDigestRecomputedIndependently() throws {
        let database = try makeDatabase("v509")

        try database.dbQueue.read { db in
            let canonical = Array(MigrationLedger.canonicalIdentifiers.prefix(5))
            let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            XCTAssertEqual(Set(applied), Set(canonical))
            XCTAssertEqual(
                try SchemaMeta.value(db, key: SchemaMetaKey.ledgerDigest),
                SHA256.hash("migrations-v1\n" + canonical.joined(separator: "\n"))
            )
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion), canonical.last)
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.appliedPhase), "V2-P4")
        }
    }

    // MARK: - V5-10 哨兵不留残留

    func testV510_SentinelLeavesNoResidue() throws {
        let queue = try makeQueue("v510", upTo: .v4_persona)
        try seedV4(queue)
        try Migrations.makeMigrator(upTo: .v5_autonomy).migrate(queue)

        try queue.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT count(*) FROM conversations WHERE id LIKE '__v5_sentinel%'"),
                0
            )
            for table in V5Autonomy.newTables {
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table) WHERE id LIKE '__v5_sentinel%'"),
                    0,
                    "\(table) 不得残留哨兵数据"
                )
            }
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA quick_check"), "ok")
        }
    }
}

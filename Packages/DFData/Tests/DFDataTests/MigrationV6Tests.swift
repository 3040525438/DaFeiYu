import XCTest
import GRDB
import DFCore
@testable import DFData

/// v6_character 迁移测试（V6-01 ~ V6-10）
final class MigrationV6Tests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFV6-\(UUID().uuidString)", isDirectory: true)
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

    /// 构造 v5 库：会话/消息/记忆/人格条目各一条 + 一条历史主动消息
    private func seedV5(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '大肥鱼', 'main', 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
            VALUES ('m1', 'uuid-m1', 'c1', 'user', 'text', '今天有点累', 'sent', 'user', 2)
            """)
            try db.execute(sql: """
            INSERT INTO memories (id, type, title, content, importance, first_seen_at)
            VALUES ('mem1', 'fact', '近况', '她最近加班多', 'normal', 1)
            """)
            try db.execute(sql: """
            INSERT INTO personas (id, kind, name, is_locked, current_version, created_at, updated_at)
            VALUES ('p-core', 'core', '大肥鱼', 1, 1, 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO persona_items (id, persona_id, section, key, value, source, updated_at)
            VALUES ('i-core', 'p-core', '核心', 'system_prompt', '我是大肥鱼。', 'user', 1)
            """)
            try db.execute(sql: """
            INSERT INTO proactive_messages (id, planned_at, text, status)
            VALUES ('pm1', 10, '今天记得早点休息', 'sent')
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

    // MARK: - V6-01 全新库 v1 → v6

    func testV601_FreshV1DatabaseMigratesToV6() throws {
        let queue = try makeQueue("v601", upTo: .v1_phase1)
        try Migrations.makeMigrator(upTo: .v6_character).migrate(queue)

        try queue.read { db in
            let ledger = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            XCTAssertEqual(Set(ledger), Set(MigrationLedger.expectedPrefix(count: 6)))
            XCTAssertEqual(
                try MigrationLedger.validatedPrefix(applied: ledger).last,
                MigrationID.v6_character.rawValue
            )
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion), "v6_character")
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.expectedMigrations), "6")
            XCTAssertEqual(try objectNames(db, names: V6Character.newTables), Set(V6Character.newTables))
            try SchemaMeta.verifyRequiredObjects(db, upTo: .v6_character)
        }
    }

    // MARK: - V6-02 v5 → v6 保留历史数据

    func testV602_IncrementalFromV5KeepsData() throws {
        let queue = try makeQueue("v602", upTo: .v5_autonomy)
        try seedV5(queue)

        let snapshot = try queue.read { db in
            (
                try V3Chat.messageFingerprint(db),
                try V4Persona.itemFingerprint(db),
                try V6Character.proactiveRows(db)
            )
        }

        try Migrations.makeMigrator(upTo: .v6_character).migrate(queue)

        try queue.read { db in
            XCTAssertEqual(try V3Chat.messageFingerprint(db), snapshot.0, "历史消息必须逐字不变")
            XCTAssertEqual(try V4Persona.itemFingerprint(db), snapshot.1, "人格条目必须逐字不变")
            XCTAssertEqual(try V6Character.proactiveRows(db), snapshot.2, "历史主动消息必须逐字不变")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM proactive_messages"), 1)
        }
    }

    // MARK: - V6-03 重复执行保护

    func testV603_RepeatedV6Rejected() throws {
        let queue = try makeQueue("v603", upTo: .v5_autonomy)
        try seedV5(queue)
        try Migrations.makeMigrator(upTo: .v6_character).migrate(queue)

        XCTAssertThrowsError(try queue.write { db in try V6Character.migrate(db) })

        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM grdb_migrations"), 6)
        }
    }

    // MARK: - V6-04 角色不得预置、历史行不得被推断

    func testV604_CharacterTablesStayEmpty() throws {
        let queue = try makeQueue("v604", upTo: .v5_autonomy)
        try seedV5(queue)
        try Migrations.makeMigrator(upTo: .v6_character).migrate(queue)

        try queue.read { db in
            for table in V6Character.newTables {
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)"),
                    0,
                    "\(table) 不得预置数据"
                )
            }
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: """
                    SELECT count(*) FROM proactive_messages
                     WHERE character_id IS NOT NULL OR mood_code IS NOT NULL
                        OR feedback_at IS NOT NULL OR is_favorite <> 0 OR trigger_kind IS NOT NULL
                    """
                ),
                0,
                "历史主动消息不得被推断角色或反馈"
            )
        }
    }

    // MARK: - V6-05 新列默认值与列顺序

    func testV605_ProactiveColumnsDefault() throws {
        let queue = try makeQueue("v605", upTo: .v5_autonomy)
        try seedV5(queue)
        try Migrations.makeMigrator(upTo: .v6_character).migrate(queue)

        try queue.read { db in
            let row = try XCTUnwrap(
                Row.fetchOne(db, sql: "SELECT * FROM proactive_messages WHERE id = 'pm1'")
            )
            XCTAssertEqual(try row.decode(String.self, forColumn: "notify_level"), "full")
            XCTAssertEqual(try row.decode(String.self, forColumn: "feedback"), "none")
            XCTAssertEqual(try row.decode(Int.self, forColumn: "is_favorite"), 0)

            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(proactive_messages)").map {
                try $0.decode(String.self, forColumn: "name")
            }
            XCTAssertEqual(columns.count, V6Character.legacyProactiveColumns.count + 8)
            XCTAssertEqual(Array(columns.suffix(8)), V6Character.newProactiveColumns)
        }
    }

    // MARK: - V6-06 库层约束与级联

    func testV606_CharacterConstraintsEnforced() throws {
        let queue = try makeQueue("v606", upTo: .v5_autonomy)
        try seedV5(queue)
        try Migrations.makeMigrator(upTo: .v6_character).migrate(queue)

        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO characters (id, name, kind, created_at, updated_at)
            VALUES ('ch1', '大肥鱼', 'builtin', 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO character_moods (id, character_id, code, name, created_at)
            VALUES ('mo1', 'ch1', 'smile', '微笑', 1)
            """)
            try db.execute(sql: """
            INSERT INTO character_states (id, character_id, mood_code, updated_at)
            VALUES ('st1', 'ch1', 'smile', 1)
            """)
        }

        // 同一角色下表情 code 唯一
        XCTAssertThrowsError(
            try queue.write { db in
                try db.execute(sql: """
                INSERT INTO character_moods (id, character_id, code, name, created_at)
                VALUES ('mo2', 'ch1', 'smile', '重复微笑', 2)
                """)
            }
        )

        // 每个角色只能有一行当前状态
        XCTAssertThrowsError(
            try queue.write { db in
                try db.execute(sql: """
                INSERT INTO character_states (id, character_id, mood_code, updated_at)
                VALUES ('st2', 'ch1', 'neutral', 2)
                """)
            }
        )

        // 删除角色必须级联清掉表情、状态与历史
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO character_state_history (id, character_id, to_mood, reason, created_at)
            VALUES ('hi1', 'ch1', 'smile', '用户互动', 3)
            """)
            try db.execute(sql: "DELETE FROM characters WHERE id = 'ch1'")
        }
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM character_moods"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM character_states"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM character_state_history"), 0)
        }
    }

    // MARK: - V6-07 必需对象门禁（52 项）

    func testV607_RequiredObjectsCountFiftyTwo() throws {
        let database = try makeDatabase("v607")

        try database.dbQueue.read { db in
            try SchemaMeta.verifyRequiredObjects(db)

            let names = V6Character.newTables + V6Character.newIndexes
            XCTAssertEqual(try objectNames(db, names: names), Set(names))

            let unique = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM pragma_index_list('character_moods')
                 WHERE name = 'ux_character_moods_code'
                """
            )
            XCTAssertEqual(try unique?.decode(Bool.self, forColumn: "unique"), true)
        }
    }

    // MARK: - V6-08 previous_* 保留 v5 原值

    func testV608_PreviousKeysPreserveV5Values() throws {
        let queue = try makeQueue("v608", upTo: .v5_autonomy)
        try seedV5(queue)

        let previous = try queue.read { db in
            (
                try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion),
                try SchemaMeta.value(db, key: SchemaMetaKey.migrationBatch),
                try SchemaMeta.value(db, key: SchemaMetaKey.migratedAt)
            )
        }
        XCTAssertEqual(previous.0, "v5_autonomy")

        try Migrations.makeMigrator(upTo: .v6_character).migrate(queue)

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
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion), "v6_character")
        }
    }

    // MARK: - V6-09 台账摘要独立复算

    func testV609_LedgerDigestRecomputedIndependently() throws {
        let database = try makeDatabase("v609")

        try database.dbQueue.read { db in
            let canonical = Array(MigrationLedger.canonicalIdentifiers.prefix(6))
            let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            XCTAssertEqual(Set(applied), Set(canonical))
            XCTAssertEqual(
                try SchemaMeta.value(db, key: SchemaMetaKey.ledgerDigest),
                SHA256.hash("migrations-v1\n" + canonical.joined(separator: "\n"))
            )
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.appliedPhase), "V2-P5")
        }
    }

    // MARK: - V6-10 哨兵不留残留

    func testV610_SentinelLeavesNoResidue() throws {
        let queue = try makeQueue("v610", upTo: .v5_autonomy)
        try seedV5(queue)
        try Migrations.makeMigrator(upTo: .v6_character).migrate(queue)

        try queue.read { db in
            for table in V6Character.newTables {
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table) WHERE id LIKE '__v6_sentinel%'"),
                    0,
                    "\(table) 不得残留哨兵数据"
                )
            }
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM proactive_messages WHERE id LIKE '__v6_sentinel%'"
                ),
                0
            )
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA quick_check"), "ok")
        }
    }
}

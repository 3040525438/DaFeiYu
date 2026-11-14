import XCTest
import GRDB
import DFCore
@testable import DFData

/// v8_chat_v2 迁移测试（V8-01 ~ V8-10）
final class MigrationV8Tests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFV8-\(UUID().uuidString)", isDirectory: true)
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
        // 锁定 v8：后续 v9 发布后，v8 的门禁与摘要断言不应被牵连
        try AppDatabase(
            paths: DatabasePaths(root: root.appendingPathComponent(name, isDirectory: true)),
            makeMigrator: { Migrations.makeMigrator(upTo: .v8_chat_v2) }
        )
    }

    /// 构造 v7 库：会话 + 2 条消息 + 记忆 + 人格条目
    private func seedV7(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '大肥鱼', 'main', 1, 1)
            """)
            for index in 1...2 {
                try db.execute(
                    sql: """
                    INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
                    VALUES (?, ?, 'c1', 'user', 'text', ?, 'sent', 'user', ?)
                    """,
                    arguments: ["m\(index)", "uuid-m\(index)", "第\(index)条", index]
                )
            }
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

    // MARK: - V8-01 全新库 v1 → v8

    func testV801_FreshV1DatabaseMigratesToV8() throws {
        let queue = try makeQueue("v801", upTo: .v1_phase1)
        try Migrations.makeMigrator(upTo: .v8_chat_v2).migrate(queue)

        try queue.read { db in
            let ledger = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            XCTAssertEqual(Set(ledger), Set(MigrationLedger.expectedPrefix(count: 8)))
            XCTAssertEqual(
                try MigrationLedger.validatedPrefix(applied: ledger).last,
                MigrationID.v8_chat_v2.rawValue
            )
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion), "v8_chat_v2")
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.expectedMigrations), "8")
            XCTAssertEqual(try objectNames(db, names: V8ChatV2.newTables), Set(V8ChatV2.newTables))
            try SchemaMeta.verifyRequiredObjects(db, upTo: .v8_chat_v2)
        }
    }

    // MARK: - V8-02 v7 → v8 保留历史数据

    func testV802_IncrementalFromV7KeepsData() throws {
        let queue = try makeQueue("v802", upTo: .v7_meta_backup)
        try seedV7(queue)

        let snapshot = try queue.read { db in
            (
                try V3Chat.messageFingerprint(db),
                try V4Persona.itemFingerprint(db)
            )
        }

        try Migrations.makeMigrator(upTo: .v8_chat_v2).migrate(queue)

        try queue.read { db in
            XCTAssertEqual(try V3Chat.messageFingerprint(db), snapshot.0, "历史消息必须逐字不变")
            XCTAssertEqual(try V4Persona.itemFingerprint(db), snapshot.1, "人格条目必须逐字不变")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM messages"), 2)
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: """
                    SELECT count(*) FROM messages
                     WHERE edited_at IS NOT NULL OR edit_count <> 0 OR revoked_at IS NOT NULL
                        OR is_favorite <> 0 OR favorited_at IS NOT NULL
                    """
                ),
                0,
                "历史消息不得被推断成已编辑/已撤回/已收藏"
            )
        }
    }

    // MARK: - V8-03 重复执行保护

    func testV803_RepeatedV8Rejected() throws {
        let queue = try makeQueue("v803", upTo: .v7_meta_backup)
        try seedV7(queue)
        try Migrations.makeMigrator(upTo: .v8_chat_v2).migrate(queue)

        XCTAssertThrowsError(try queue.write { db in try V8ChatV2.migrate(db) })

        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM grdb_migrations"), 8)
        }
    }

    // MARK: - V8-04 新表与 FTS 不得预置

    func testV804_NewTablesStayEmpty() throws {
        let queue = try makeQueue("v804", upTo: .v7_meta_backup)
        try seedV7(queue)
        try Migrations.makeMigrator(upTo: .v8_chat_v2).migrate(queue)

        try queue.read { db in
            for table in V8ChatV2.newTables {
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)"),
                    0,
                    "\(table) 不得预置数据"
                )
            }
        }
    }

    // MARK: - V8-05 消息新列与列顺序

    func testV805_MessageColumnsDefault() throws {
        let queue = try makeQueue("v805", upTo: .v7_meta_backup)
        try seedV7(queue)
        try Migrations.makeMigrator(upTo: .v8_chat_v2).migrate(queue)

        try queue.read { db in
            let row = try XCTUnwrap(
                Row.fetchOne(db, sql: "SELECT * FROM messages WHERE id = 'm1'")
            )
            XCTAssertEqual(try row.decode(Int.self, forColumn: "edit_count"), 0)
            XCTAssertEqual(try row.decode(Int.self, forColumn: "is_favorite"), 0)

            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(messages)").map {
                try $0.decode(String.self, forColumn: "name")
            }
            XCTAssertEqual(columns.count, V8ChatV2.legacyMessageColumns.count + 6)
            XCTAssertEqual(Array(columns.suffix(6)), V8ChatV2.newMessageColumns)
        }
    }

    // MARK: - V8-06 库层约束：编辑版本唯一、一天一篇、软删后可重建

    func testV806_ChatV2ConstraintsEnforced() throws {
        let queue = try makeQueue("v806", upTo: .v7_meta_backup)
        try seedV7(queue)
        try Migrations.makeMigrator(upTo: .v8_chat_v2).migrate(queue)

        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO message_edits (id, message_id, version, before_text, after_text, created_at)
            VALUES ('e1', 'm1', 1, '原文', '改后', 10)
            """)
            try db.execute(sql: """
            INSERT INTO diary_entries (id, entry_date, content, created_at, updated_at)
            VALUES ('d1', '2026-11-15', '今天很平静', 10, 10)
            """)
        }

        // 同一消息的编辑版本号必须唯一
        XCTAssertThrowsError(
            try queue.write { db in
                try db.execute(sql: """
                INSERT INTO message_edits (id, message_id, version, before_text, after_text, created_at)
                VALUES ('e2', 'm1', 1, '原文', '再次', 11)
                """)
            }
        )

        // 同一天只能有一篇未删除日记
        XCTAssertThrowsError(
            try queue.write { db in
                try db.execute(sql: """
                INSERT INTO diary_entries (id, entry_date, content, created_at, updated_at)
                VALUES ('d2', '2026-11-15', '重复', 11, 11)
                """)
            }
        )

        // 软删后同一天允许重建
        try queue.write { db in
            try db.execute(sql: "UPDATE diary_entries SET deleted_at = 12 WHERE id = 'd1'")
            try db.execute(sql: """
            INSERT INTO diary_entries (id, entry_date, content, created_at, updated_at)
            VALUES ('d3', '2026-11-15', '重建', 13, 13)
            """)
        }
        try queue.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT count(*) FROM diary_entries WHERE entry_date = '2026-11-15'"),
                2
            )
        }
    }

    // MARK: - V8-07 必需对象门禁（73 项）

    func testV807_RequiredObjectsCountSeventyThree() throws {
        let database = try makeDatabase("v807")

        try database.dbQueue.read { db in
            try SchemaMeta.verifyRequiredObjects(db, upTo: .v8_chat_v2)

            let names = V8ChatV2.newTables + V8ChatV2.newIndexes
            XCTAssertEqual(try objectNames(db, names: names), Set(names))

            let partial = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM pragma_index_list('diary_entries') WHERE name = 'ux_diary_entries_date'
                """
            )
            XCTAssertEqual(try partial?.decode(Bool.self, forColumn: "partial"), true)
        }
    }

    // MARK: - V8-08 previous_* 保留 v7 原值

    func testV808_PreviousKeysPreserveV7Values() throws {
        let queue = try makeQueue("v808", upTo: .v7_meta_backup)
        try seedV7(queue)

        let previous = try queue.read { db in
            (
                try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion),
                try SchemaMeta.value(db, key: SchemaMetaKey.migrationBatch),
                try SchemaMeta.value(db, key: SchemaMetaKey.migratedAt)
            )
        }
        XCTAssertEqual(previous.0, "v7_meta_backup")

        try Migrations.makeMigrator(upTo: .v8_chat_v2).migrate(queue)

        try queue.read { db in
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.previousSchemaVersion), previous.0)
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.previousMigrationBatch), previous.1)
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.previousMigratedAt), previous.2)
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion), "v8_chat_v2")
        }
    }

    // MARK: - V8-09 台账摘要独立复算

    func testV809_LedgerDigestRecomputedIndependently() throws {
        let database = try makeDatabase("v809")

        try database.dbQueue.read { db in
            let canonical = Array(MigrationLedger.canonicalIdentifiers.prefix(8))
            let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            XCTAssertEqual(Set(applied), Set(canonical))
            XCTAssertEqual(
                try SchemaMeta.value(db, key: SchemaMetaKey.ledgerDigest),
                SHA256.hash("migrations-v1\n" + canonical.joined(separator: "\n"))
            )
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.appliedPhase), "V2-P7")
        }
    }

    // MARK: - V8-10 哨兵不留残留

    func testV810_SentinelLeavesNoResidue() throws {
        let queue = try makeQueue("v810", upTo: .v7_meta_backup)
        try seedV7(queue)
        try Migrations.makeMigrator(upTo: .v8_chat_v2).migrate(queue)

        try queue.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT count(*) FROM message_edits WHERE id LIKE '__v8_sentinel%'"),
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT count(*) FROM diary_entries WHERE id LIKE '__v8_sentinel%'"),
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT count(*) FROM diary_entry_versions WHERE id LIKE '__v8_sentinel%'"),
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT count(*) FROM message_fts WHERE message_id LIKE '__v8_sentinel%'"),
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT count(*) FROM diary_fts WHERE diary_id LIKE '__v8_sentinel%'"),
                0
            )
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA quick_check"), "ok")
        }
    }
}

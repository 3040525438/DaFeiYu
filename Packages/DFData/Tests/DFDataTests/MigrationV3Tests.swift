import XCTest
import GRDB
import DFCore
@testable import DFData

/// v3_chat 迁移测试（M01–M12）
final class MigrationV3Tests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFV3-\(UUID().uuidString)", isDirectory: true)
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
        try AppDatabase(paths: DatabasePaths(root: root.appendingPathComponent(name, isDirectory: true)))
    }

    /// 逐行取 14 列的真实值（quote 后比较，NULL 与空串可区分）
    private func legacyRowLines(_ db: Database) throws -> [String] {
        let expressions = V3Chat.legacyColumns.map { "quote(\($0))" }.joined(separator: " || char(31) || ")
        return try String.fetchAll(db, sql: "SELECT \(expressions) AS line FROM messages ORDER BY id")
    }

    /// 构造一个 v2 库：1 个会话 + 23 条消息（其中 1 条软删）+ 2 条记忆
    private func seedV2(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '大肥鱼', 'main', 1, 1)
            """)
            for index in 1...23 {
                try db.execute(
                    sql: """
                    INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin,
                                          created_at, sent_at, deleted_at)
                    VALUES (?, ?, 'c1', ?, 'text', ?, 'sent', ?, ?, ?, ?)
                    """,
                    arguments: [
                        "m\(String(format: "%02d", index))",
                        "uuid-\(index)",
                        index % 2 == 0 ? "assistant" : "user",
                        "第\(index)条",
                        index % 2 == 0 ? "reply" : "user",
                        Int64(index) * 1000,
                        Int64(index) * 1000 + 10,
                        index == 5 ? Int64(index) * 1000 + 20 : nil
                    ]
                )
            }
            try db.execute(sql: """
            INSERT INTO memories (id, type, title, content, importance, first_seen_at)
            VALUES ('mem1', 'fact', '摄影', '今天去看了摄影展', 'high', 1)
            """)
            try db.execute(sql: """
            INSERT INTO memories (id, type, title, content, importance, first_seen_at)
            VALUES ('mem2', 'fact', '猫', '她养了一只猫', 'normal', 2)
            """)
        }
    }

    private func memoryObjectSnapshot(_ db: Database) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
            SELECT name FROM sqlite_master
            WHERE name IN ('memories','memory_fts','memory_scopes','v_memory_user',
                           'v_memory_shared','v_memory_self','v_memory_stats')
            ORDER BY name
            """
        )
    }

    // MARK: - M01 v1 → v3

    func testM01_FreshV1DatabaseMigratesToV3() throws {
        let queue = try makeQueue("m01", upTo: .v1_phase1)
        try Migrations.migrator.migrate(queue)

        try queue.read { db in
            let ledger = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            XCTAssertEqual(Set(ledger), ["v1_phase1", "v2_memory", "v3_chat"])
            XCTAssertEqual(
                try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion),
                "v3_chat"
            )
            XCTAssertEqual(
                try SchemaMeta.value(db, key: SchemaMetaKey.expectedMigrations),
                "3"
            )
            // v3 结构必须存在
            let tables = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('message_groups','message_references')"
            )
            XCTAssertEqual(Set(tables), ["message_groups", "message_references"])
        }
    }

    // MARK: - M02 v2 → v3

    func testM02_IncrementalFromV2KeepsData() throws {
        let queue = try makeQueue("m02", upTo: .v2_memory)
        try seedV2(queue)

        let before = try queue.read { db in try legacyRowLines(db) }
        try Migrations.migrator.migrate(queue)
        let after = try queue.read { db in try legacyRowLines(db) }

        XCTAssertEqual(after, before, "23 条历史消息 14 列逐字段必须完全不变")
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM messages"), 23)
            XCTAssertEqual(
                try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion),
                "v3_chat"
            )
        }
    }

    // MARK: - M03 重复执行保护

    func testM03_RepeatedV3Rejected() throws {
        let queue = try makeQueue("m03", upTo: .v2_memory)
        try Migrations.migrator.migrate(queue)

        let before = try queue.read { db in try legacyRowLines(db) }
        var thrown = false
        do {
            try queue.write { db in
                try V3Chat.migrate(db)
            }
        } catch {
            thrown = true
        }
        XCTAssertTrue(thrown, "v3_chat 重复执行必须抛错")

        let after = try queue.read { db in try legacyRowLines(db) }
        XCTAssertEqual(after, before)
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM grdb_migrations"), 3)
        }
    }

    // MARK: - M04 历史消息不变 + 新列 NULL

    func testM04_HistoricalMessagesUnchanged() throws {
        let queue = try makeQueue("m04", upTo: .v2_memory)
        try seedV2(queue)
        let before = try queue.read { db in try legacyRowLines(db) }

        try Migrations.migrator.migrate(queue)

        try queue.read { db in
            XCTAssertEqual(try legacyRowLines(db), before)
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(messages)").map {
                try $0.decode(String.self, forColumn: "name")
            }
            XCTAssertEqual(columns.count, 16, "messages 应为 14 + 2 列")
            XCTAssertEqual(Array(columns.prefix(14)), V3Chat.legacyColumns, "既有 14 列顺序不得改变")
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM messages WHERE group_id IS NOT NULL OR seq_in_group IS NOT NULL"
                ),
                0,
                "历史行两新列必须为 NULL（不回填）"
            )
        }
    }

    // MARK: - M05 软删保留

    func testM05_SoftDeletedRowsPreserved() throws {
        let queue = try makeQueue("m05", upTo: .v2_memory)
        try seedV2(queue)

        try Migrations.migrator.migrate(queue)

        try queue.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE deleted_at IS NOT NULL"),
                1
            )
            let row = try Row.fetchOne(
                db,
                sql: "SELECT text, deleted_at FROM messages WHERE id = 'm05'"
            )
            XCTAssertEqual(try row?.decode(String.self, forColumn: "text"), "第5条")
            XCTAssertEqual(try row?.decode(Int64.self, forColumn: "deleted_at"), 5020)
        }
    }

    // MARK: - M06 记忆系统不变

    func testM06_MemoryObjectsUntouched() throws {
        let queue = try makeQueue("m06", upTo: .v2_memory)
        try seedV2(queue)

        let objectsBefore = try queue.read { db in try memoryObjectSnapshot(db) }
        let memoriesBefore = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT id || ':' || content FROM memories ORDER BY id")
        }

        try Migrations.migrator.migrate(queue)

        try queue.read { db in
            XCTAssertEqual(try memoryObjectSnapshot(db), objectsBefore)
            XCTAssertEqual(
                try String.fetchAll(db, sql: "SELECT id || ':' || content FROM memories ORDER BY id"),
                memoriesBefore
            )
        }
    }

    // MARK: - M07 digest 独立复算

    func testM07_LedgerDigestRecomputedIndependently() throws {
        let database = try makeDatabase("m07")

        try database.dbQueue.read { db in
            let stored = try SchemaMeta.value(db, key: SchemaMetaKey.ledgerDigest)
            XCTAssertNotNil(stored)

            // 独立实现：直接对规范清单前 3 项做 SHA-256，不经过 SchemaMeta
            let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            XCTAssertEqual(applied.count, 3)
            let canonical = ["v1_phase1", "v2_memory", "v3_chat"]
            XCTAssertEqual(Set(applied), Set(canonical))
            let expected = SHA256.hash("migrations-v1\n" + canonical.joined(separator: "\n"))
            XCTAssertEqual(stored, expected, "库内 digest 必须等于独立复算值")

            XCTAssertEqual(
                try SchemaMeta.value(db, key: SchemaMetaKey.expectedMigrations),
                String(canonical.count)
            )
            XCTAssertEqual(
                try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion),
                canonical.last
            )
        }
    }

    // MARK: - M08 16 个必需对象

    func testM08_RequiredObjectsSixteen() throws {
        let database = try makeDatabase("m08")

        try database.dbQueue.read { db in
            try SchemaMeta.verifyRequiredObjects(db)

            let required = [
                "schema_meta", "memory_scopes", "memory_fts", "v_memory_user", "v_memory_shared",
                "v_memory_self", "v_memory_stats", "ux_memories_dedupe", "ix_memories_scope_time",
                "ix_persona_items_tier", "message_groups", "message_references",
                "ux_message_groups_turn", "ix_message_groups_status", "ux_messages_group_seq",
                "ix_message_refs_ref"
            ]
            let quoted = required.map { "'\($0)'" }.joined(separator: ",")
            let found = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE name IN (\(quoted))"
            )
            XCTAssertEqual(Set(found), Set(required))
            XCTAssertEqual(required.count, 16)

            // seq 索引必须是唯一索引且为部分索引
            let indexRow = try Row.fetchOne(
                db,
                sql: "SELECT * FROM pragma_index_list('messages') WHERE name = 'ux_messages_group_seq'"
            )
            XCTAssertEqual(try indexRow?.decode(Bool.self, forColumn: "unique"), true)
            XCTAssertEqual(try indexRow?.decode(Bool.self, forColumn: "partial"), true)

            // messages 两列必须存在
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(messages)").map {
                try $0.decode(String.self, forColumn: "name")
            }
            XCTAssertTrue(columns.contains("group_id"))
            XCTAssertTrue(columns.contains("seq_in_group"))
        }
    }

    // MARK: - M09 迁移失败降级

    func testM09_MigrationFailureFallsBackReadOnly() async throws {
        let dir = root.appendingPathComponent("m09", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let paths = DatabasePaths(root: dir)

        let database = try AppDatabase(paths: paths, makeMigrator: {
            var migrator = DatabaseMigrator()
            migrator.registerMigration("v1_phase1") { db in
                try db.execute(sql: """
                CREATE TABLE conversations (id TEXT PRIMARY KEY, title TEXT NOT NULL,
                    kind TEXT NOT NULL DEFAULT 'main', created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL, archived_at INTEGER)
                """)
                try db.execute(sql: """
                CREATE TABLE messages (id TEXT PRIMARY KEY, client_uuid TEXT NOT NULL UNIQUE,
                    conversation_id TEXT NOT NULL, role TEXT NOT NULL, kind TEXT NOT NULL,
                    text TEXT NOT NULL DEFAULT '', status TEXT NOT NULL, origin TEXT NOT NULL,
                    reply_to_id TEXT, created_at INTEGER NOT NULL, sent_at INTEGER,
                    model_config_id TEXT, emotion_state_id TEXT, deleted_at INTEGER)
                """)
                try db.execute(sql: "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            }
            migrator.registerMigration("v2_memory") { db in
                try SchemaMeta.createTable(db)
                try SchemaMeta.write(db, key: SchemaMetaKey.schemaVersion, value: "v2_memory", at: 1)
                try SchemaMeta.write(db, key: SchemaMetaKey.ledgerDigest, value: "stub", at: 1)
                try SchemaMeta.write(db, key: SchemaMetaKey.expectedMigrations, value: "2", at: 1)
            }
            migrator.registerMigration("v3_chat") { _ in
                throw DFError.database("注入：v3_chat 失败")
            }
            return migrator
        })

        XCTAssertTrue(database.isReadOnly)
        XCTAssertNotNil(database.migrationFailureReason)
        XCTAssertEqual(database.currentSchemaVersion, "v2_memory")

        // v3 结构不得半途留下
        try database.dbQueue.read { db in
            let created = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM sqlite_master WHERE name IN ('message_groups','message_references')"
            )
            XCTAssertEqual(created, 0)
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(messages)").map {
                try $0.decode(String.self, forColumn: "name")
            }
            XCTAssertEqual(columns.count, 14, "整体回滚后 messages 仍是 14 列")
        }

        // 写入被拦截
        do {
            try await database.write { db in
                try db.execute(sql: "INSERT INTO settings(key, value) VALUES('probe', 'blocked')")
            }
            XCTFail("迁移失败状态必须拒绝写入")
        } catch {
            // 预期
        }
    }

    // MARK: - M10 新代码读新库

    func testM10_NewCodeReadsNewDatabase() throws {
        let database = try makeDatabase("m10")

        try database.dbQueue.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '大肥鱼', 'main', 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO message_groups (id, conversation_id, turn_index, kind, status, opened_at)
            VALUES ('g1', 'c1', 1, 'chat', 'open', 10)
            """)
            try db.execute(sql: """
            INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin,
                                  created_at, group_id, seq_in_group)
            VALUES ('m1', 'u1', 'c1', 'user', 'text', '在吗', 'sent', 'user', 10, 'g1', 0)
            """)
        }

        try database.dbQueue.read { db in
            let message = try Message.fetchOne(db, key: "m1")
            XCTAssertEqual(message?.groupID, "g1")
            XCTAssertEqual(message?.seqInGroup, 0)
            XCTAssertEqual(message?.status, .sent)
        }
    }

    // MARK: - M11 新代码读 v2 库（降级态）

    func testM11_NewCodeReadsV2Database() throws {
        let queue = try makeQueue("m11", upTo: .v2_memory)
        try seedV2(queue)

        try queue.read { db in
            // 该库没有 group_id / seq_in_group 列，读取不得崩溃
            let messages = try Message.fetchAll(db, sql: "SELECT * FROM messages ORDER BY id")
            XCTAssertEqual(messages.count, 23)
            XCTAssertEqual(messages.first?.text, "第1条")
            XCTAssertNil(messages.first?.groupID)
            XCTAssertNil(messages.first?.seqInGroup)
            XCTAssertEqual(messages.first?.status, .sent)
        }
    }

    // MARK: - M12 previous_* 保留 P1 原值

    func testM12_PreviousKeysPreserveV2Values() throws {
        let queue = try makeQueue("m12", upTo: .v2_memory)
        try seedV2(queue)

        let previous = try queue.read { db in
            (
                try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion),
                try SchemaMeta.value(db, key: SchemaMetaKey.migrationBatch),
                try SchemaMeta.value(db, key: SchemaMetaKey.migratedAt)
            )
        }
        XCTAssertEqual(previous.0, "v2_memory")
        XCTAssertNotNil(previous.1)
        XCTAssertNotNil(previous.2)

        try Migrations.migrator.migrate(queue)

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
            // 新值必须已切换（migrated_at 更新为本次时间，不早于旧值）
            XCTAssertEqual(
                try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion),
                "v3_chat"
            )
            let newMigratedAt = try SchemaMeta.value(db, key: SchemaMetaKey.migratedAt)
            XCTAssertGreaterThanOrEqual(Int64(newMigratedAt ?? "") ?? 0, Int64(previous.2 ?? "") ?? 0)
        }
    }
}

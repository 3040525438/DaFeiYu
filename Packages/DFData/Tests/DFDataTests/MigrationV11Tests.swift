import XCTest
import GRDB
import DFCore
@testable import DFData

/// v11_local_models 迁移测试（V11-01 ~ V11-10）
final class MigrationV11Tests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFV11-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

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

    private func seedV10(_ queue: DatabaseQueue) throws {
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
            INSERT INTO memories (id, type, title, content, importance, first_seen_at, scope)
            VALUES ('mem1', 'fact', '作息', '她常熬夜', 'normal', 1, 'shared')
            """)
            try db.execute(sql: """
            INSERT INTO model_configs (id, name, base_url, model_id, key_ref, created_at, updated_at)
            VALUES ('cfg1', '云端', 'https://example.com', 'gpt', 'key-1', 1, 1)
            """)
        }
    }

    func testV1101_FreshDatabaseMigratesToV11() throws {
        let queue = try makeQueue("v1101", upTo: .v1_phase1)
        try Migrations.makeMigrator(upTo: .v11_local_models).migrate(queue)

        try queue.read { db in
            let ledger = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            XCTAssertEqual(ledger.count, 11)
            XCTAssertEqual(
                try MigrationLedger.validatedPrefix(applied: ledger).last,
                MigrationID.v11_local_models.rawValue
            )
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion), "v11_local_models")
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.expectedMigrations), "11")
            try SchemaMeta.verifyRequiredObjects(db, upTo: .v11_local_models)
        }
    }

    func testV1102_IncrementalFromV10KeepsData() throws {
        let queue = try makeQueue("v1102", upTo: .v10_multimodal)
        try seedV10(queue)

        let before = try queue.read { db in
            (try V3Chat.messageFingerprint(db), try V4Persona.itemFingerprint(db))
        }
        try Migrations.makeMigrator(upTo: .v11_local_models).migrate(queue)

        try queue.read { db in
            XCTAssertEqual(try V3Chat.messageFingerprint(db), before.0)
            XCTAssertEqual(try V4Persona.itemFingerprint(db), before.1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM messages"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM memories"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM model_configs"), 1)
        }
    }

    func testV1103_RejectsRerun() throws {
        let queue = try makeQueue("v1103", upTo: .v11_local_models)
        XCTAssertThrowsError(try queue.write { db in
            try V11LocalModels.migrate(db)
        }) { error in
            XCTAssertTrue(String(describing: error).contains("v11_local_models"))
        }
    }

    func testV1104_SHAUniqueIndexAllowsMultipleNulls() throws {
        let queue = try makeQueue("v1104", upTo: .v11_local_models)
        try queue.write { db in
            for index in 0..<3 {
                try db.execute(sql: """
                INSERT INTO local_models (id, name, created_at, updated_at)
                VALUES (?, '未下载模型', 1, 1)
                """, arguments: ["m\(index)"])
            }
        }
        let count = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM local_models") ?? -1
        }
        XCTAssertEqual(count, 3, "未下载模型 sha256 为 NULL 时不得互相冲突")
    }

    func testV1105_DefaultStatusIsNotDownloaded() throws {
        let queue = try makeQueue("v1105", upTo: .v11_local_models)
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO local_models (id, name, created_at, updated_at) VALUES ('m1', '模型', 1, 1)
            """)
        }
        try queue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT status, downloaded_bytes, wifi_only FROM local_models WHERE id='m1'")
            XCTAssertEqual(String.fromDatabaseValue(row?["status"] ?? .null), "not_downloaded")
            XCTAssertEqual(Int.fromDatabaseValue(row?["downloaded_bytes"] ?? .null), 0)
            XCTAssertEqual(Int.fromDatabaseValue(row?["wifi_only"] ?? .null), 1, "默认仅 Wi-Fi 下载")
        }
    }

    func testV1106_EventsCascadeWithModel() throws {
        let queue = try makeQueue("v1106", upTo: .v11_local_models)
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO local_models (id, name, created_at, updated_at) VALUES ('m1', '模型', 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO model_runtime_events (id, model_id, kind, created_at) VALUES ('e1', 'm1', 'load', 1)
            """)
        }
        try queue.write { db in
            try db.execute(sql: "DELETE FROM local_models WHERE id='m1'")
        }
        let remaining = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM model_runtime_events") ?? -1
        }
        XCTAssertEqual(remaining, 0)
    }

    func testV1107_PreviousMetaKeys() throws {
        let queue = try makeQueue("v1107", upTo: .v10_multimodal)
        try Migrations.makeMigrator(upTo: .v11_local_models).migrate(queue)
        try queue.read { db in
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.previousSchemaVersion), "v10_multimodal")
            XCTAssertNotNil(try SchemaMeta.value(db, key: SchemaMetaKey.previousMigrationBatch))
            XCTAssertNotNil(try SchemaMeta.value(db, key: SchemaMetaKey.previousMigratedAt))
        }
    }

    func testV1108_NewTablesStartEmpty() throws {
        let queue = try makeQueue("v1108", upTo: .v10_multimodal)
        try seedV10(queue)
        try Migrations.makeMigrator(upTo: .v11_local_models).migrate(queue)
        try queue.read { db in
            for table in V11LocalModels.newTables {
                let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? -1
                XCTAssertEqual(count, 0, "\(table) 不得预置数据")
            }
        }
    }

    func testV1109_QuickCheckPasses() throws {
        let queue = try makeQueue("v1109", upTo: .v11_local_models)
        try queue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA quick_check")?.lowercased(), "ok")
        }
    }

    func testV1110_DoesNotTouchMemoryOrSearchObjects() throws {
        let queue = try makeQueue("v1110", upTo: .v10_multimodal)
        let before = try queue.read { db in
            try Set(String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE name IN ('memory_fts','message_fts','attachment_text_fts','v_memory_user','v_memory_shared','v_memory_self')"
            ))
        }
        try Migrations.makeMigrator(upTo: .v11_local_models).migrate(queue)
        try queue.read { db in
            let after = try Set(String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE name IN ('memory_fts','message_fts','attachment_text_fts','v_memory_user','v_memory_shared','v_memory_self')"
            ))
            XCTAssertEqual(after, before)
        }
    }
}

import XCTest
import GRDB
import DFCore
@testable import DFData

/// v10_multimodal 迁移测试（V10-01 ~ V10-10）
final class MigrationV10Tests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFV10-\(UUID().uuidString)", isDirectory: true)
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

    /// 构造 v9 库：一条会话 / 一条消息 / 一个历史附件 / 一条记忆
    private func seedV9(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '大肥鱼', 'main', 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
            VALUES ('m1', 'uuid-m1', 'c1', 'user', 'text', '今天拍了照片', 'sent', 'user', 2)
            """)
            try db.execute(sql: """
            INSERT INTO attachments (id, sha256, kind, rel_path, byte_size, mime, created_at)
            VALUES ('a1', 'sha-a1', 'image', 'att/a1.png', 1024, 'image/png', 3)
            """)
            try db.execute(sql: """
            INSERT INTO message_attachments (message_id, attachment_id, sort) VALUES ('m1', 'a1', 0)
            """)
            try db.execute(sql: """
            INSERT INTO memories (id, type, title, content, importance, first_seen_at, scope)
            VALUES ('mem1', 'event', '拍照', '用户拍了照片', 'normal', 1, 'shared')
            """)
        }
    }

    private func objectNames(_ db: Database, names: [String]) throws -> Set<String> {
        let quoted = names.map { "'\($0)'" }.joined(separator: ",")
        return Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE name IN (\(quoted))"))
    }

    private func columnNames(_ db: Database, table: String) throws -> [String] {
        try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map {
            try $0.decode(String.self, forColumn: "name")
        }
    }

    // MARK: - V10-01 全新库 v1 → v10

    func testV1001_FreshDatabaseMigratesToV10() throws {
        let queue = try makeQueue("v1001", upTo: .v1_phase1)
        // 锁定 v10：生产 migrator 会随新版本前移
        try Migrations.makeMigrator(upTo: .v10_multimodal).migrate(queue)

        try queue.read { db in
            let ledger = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            XCTAssertEqual(ledger.count, 10)
            XCTAssertEqual(Set(ledger), Set(MigrationLedger.expectedPrefix(count: 10)))
            XCTAssertEqual(
                try MigrationLedger.validatedPrefix(applied: ledger).last,
                MigrationID.v10_multimodal.rawValue
            )
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion), "v10_multimodal")
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.expectedMigrations), "10")
            XCTAssertEqual(try objectNames(db, names: V10Multimodal.newTables), Set(V10Multimodal.newTables))
            try SchemaMeta.verifyRequiredObjects(db, upTo: .v10_multimodal)
        }
    }

    // MARK: - V10-02 v9 → v10 保留历史数据且不回填

    func testV1002_IncrementalFromV9KeepsDataWithoutBackfill() throws {
        let queue = try makeQueue("v1002", upTo: .v9_astrbot)
        try seedV9(queue)

        let snapshot = try queue.read { db in
            (
                try V3Chat.messageFingerprint(db),
                try V4Persona.itemFingerprint(db),
                try columnNames(db, table: "attachments")
            )
        }

        try Migrations.makeMigrator(upTo: .v10_multimodal).migrate(queue)

        try queue.read { db in
            XCTAssertEqual(try V3Chat.messageFingerprint(db), snapshot.0, "历史消息必须逐字不变")
            XCTAssertEqual(try V4Persona.itemFingerprint(db), snapshot.1, "人格条目必须逐字不变")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM messages"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM attachments"), 1)

            let columns = try columnNames(db, table: "attachments")
            XCTAssertEqual(Array(columns.prefix(snapshot.2.count)), snapshot.2, "既有附件列顺序不得变化")
            XCTAssertEqual(
                Array(columns.suffix(V10Multimodal.newAttachmentColumns.count)),
                V10Multimodal.newAttachmentColumns
            )

            // 历史附件不得被伪造尺寸/时长/缩略图
            let row = try Row.fetchOne(db, sql: "SELECT width, height, duration_ms, thumbnail_rel_path FROM attachments WHERE id = 'a1'")
            XCTAssertNil(Int.fromDatabaseValue(row?["width"] ?? .null))
            XCTAssertNil(Int.fromDatabaseValue(row?["height"] ?? .null))
            XCTAssertNil(Int.fromDatabaseValue(row?["duration_ms"] ?? .null))
            XCTAssertNil(String.fromDatabaseValue(row?["thumbnail_rel_path"] ?? .null))
        }
    }

    // MARK: - V10-03 不可重复执行

    func testV1003_MigrationRejectsRerun() throws {
        let queue = try makeQueue("v1003", upTo: .v10_multimodal)
        XCTAssertThrowsError(try queue.write { db in
            try V10Multimodal.migrate(db)
        }) { error in
            XCTAssertTrue(String(describing: error).contains("v10_multimodal"))
        }
    }

    // MARK: - V10-04 同一附件的同类派生文本唯一

    func testV1004_AttachmentTextUniquePerKind() throws {
        let queue = try makeQueue("v1004", upTo: .v10_multimodal)
        try seedV9(queue)

        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO attachment_texts (id, attachment_id, kind, text, created_at, updated_at)
            VALUES ('t1', 'a1', 'ocr', '海报上的字', 1, 1)
            """)
        }
        XCTAssertThrowsError(try queue.write { db in
            try db.execute(sql: """
            INSERT INTO attachment_texts (id, attachment_id, kind, text, created_at, updated_at)
            VALUES ('t2', 'a1', 'ocr', '重复', 2, 2)
            """)
        })
    }

    // MARK: - V10-05 同附件不同 kind 允许并存

    func testV1005_AttachmentTextAllowsOcrAndTranscriptTogether() throws {
        let queue = try makeQueue("v1005", upTo: .v10_multimodal)
        try seedV9(queue)

        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO attachment_texts (id, attachment_id, kind, text, created_at, updated_at)
            VALUES ('t1', 'a1', 'ocr', '画面文字', 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO attachment_texts (id, attachment_id, kind, text, created_at, updated_at)
            VALUES ('t2', 'a1', 'transcript', '语音转写', 2, 2)
            """)
        }
        let count = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM attachment_texts WHERE attachment_id = 'a1'")
        }
        XCTAssertEqual(count, 2)
    }

    // MARK: - V10-06 删除附件级联清理派生文本

    func testV1006_DeletingAttachmentCascadesTexts() throws {
        let queue = try makeQueue("v1006", upTo: .v10_multimodal)
        try seedV9(queue)

        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO attachment_texts (id, attachment_id, kind, text, created_at, updated_at)
            VALUES ('t1', 'a1', 'ocr', '画面文字', 1, 1)
            """)
        }
        try queue.write { db in
            try db.execute(sql: "DELETE FROM message_attachments WHERE attachment_id = 'a1'")
            try db.execute(sql: "DELETE FROM attachments WHERE id = 'a1'")
        }
        let remaining = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM attachment_texts") ?? -1
        }
        XCTAssertEqual(remaining, 0, "派生文本必须随附件级联删除")
    }

    // MARK: - V10-07 多图分析记录可多条且默认 pending

    func testV1007_ImageAnalysesSupportsMultipleRowsPerMessage() throws {
        let queue = try makeQueue("v1007", upTo: .v10_multimodal)
        try seedV9(queue)

        try queue.write { db in
            for index in 0..<3 {
                try db.execute(sql: """
                INSERT INTO image_analyses
                    (id, conversation_id, message_id, attachment_ids_json, prompt, result, created_at)
                VALUES (?, 'c1', 'm1', '["a1"]', '比较这几张', '', ?)
                """, arguments: ["ia\(index)", 10 + index])
            }
        }

        try queue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM image_analyses WHERE message_id = 'm1'")
            XCTAssertEqual(count, 3)
            let status = try String.fetchOne(db, sql: "SELECT status FROM image_analyses LIMIT 1")
            XCTAssertEqual(status, "pending")
        }
    }

    // MARK: - V10-08 previous_* 元数据三键

    func testV1008_WritesPreviousMetaKeys() throws {
        let queue = try makeQueue("v1008", upTo: .v9_astrbot)
        try Migrations.makeMigrator(upTo: .v10_multimodal).migrate(queue)

        try queue.read { db in
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.previousSchemaVersion), "v9_astrbot")
            XCTAssertNotNil(try SchemaMeta.value(db, key: SchemaMetaKey.previousMigrationBatch))
            XCTAssertNotNil(try SchemaMeta.value(db, key: SchemaMetaKey.previousMigratedAt))
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.ledgerDigest),
                           MigrationLedger.digest(prefix: MigrationLedger.canonicalIdentifiers))
        }
    }

    // MARK: - V10-09 迁移后完整性与外围对象不受影响

    func testV1009_KeepsMemoryObjectsAndPassesIntegrity() throws {
        let queue = try makeQueue("v1009", upTo: .v9_astrbot)
        try seedV9(queue)
        let before = try queue.read { db in
            try Set(String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE name LIKE 'v_memory%' OR name = 'memory_fts'"
            ))
        }

        try Migrations.makeMigrator(upTo: .v10_multimodal).migrate(queue)

        try queue.read { db in
            let after = try Set(String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE name LIKE 'v_memory%' OR name = 'memory_fts'"
            ))
            XCTAssertEqual(after, before)
            let quick = try String.fetchOne(db, sql: "PRAGMA quick_check")
            XCTAssertEqual(quick?.lowercased(), "ok")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM memories"), 1)
        }
    }

    // MARK: - V10-10 新表初始为空（不得预置派生数据）

    func testV1010_NewTablesStartEmpty() throws {
        let queue = try makeQueue("v1010", upTo: .v9_astrbot)
        try seedV9(queue)
        try Migrations.makeMigrator(upTo: .v10_multimodal).migrate(queue)

        try queue.read { db in
            for table in V10Multimodal.newTables {
                let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? -1
                XCTAssertEqual(count, 0, "\(table) 不得预置数据")
            }
        }
    }
}

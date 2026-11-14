import XCTest
import GRDB
import DFCore
@testable import DFData

/// v7_meta_backup 迁移测试（V7-01 ~ V7-10）
final class MigrationV7Tests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFV7-\(UUID().uuidString)", isDirectory: true)
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
        // 锁定 v7：后续 v8/v9 发布后，v7 的门禁与摘要断言不应被牵连
        try AppDatabase(
            paths: DatabasePaths(root: root.appendingPathComponent(name, isDirectory: true)),
            makeMigrator: { Migrations.makeMigrator(upTo: .v7_meta_backup) }
        )
    }

    /// 构造 v6 库：会话/消息/记忆/人格各一条 + 一条历史附件
    private func seedV6(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '大肥鱼', 'main', 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
            VALUES ('m1', 'uuid-m1', 'c1', 'user', 'text', '周末去看展', 'sent', 'user', 2)
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
            try db.execute(sql: """
            INSERT INTO attachments (id, sha256, kind, rel_path, byte_size, mime, created_at)
            VALUES ('a1', 'sha-a1', 'image', 'attachments/a1.png', 12, 'image/png', 3)
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

    // MARK: - V7-01 全新库 v1 → v7

    func testV701_FreshV1DatabaseMigratesToV7() throws {
        let queue = try makeQueue("v701", upTo: .v1_phase1)
        try Migrations.makeMigrator(upTo: .v7_meta_backup).migrate(queue)

        try queue.read { db in
            let ledger = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            XCTAssertEqual(Set(ledger), Set(MigrationLedger.expectedPrefix(count: 7)))
            XCTAssertEqual(
                try MigrationLedger.validatedPrefix(applied: ledger).last,
                MigrationID.v7_meta_backup.rawValue
            )
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion), "v7_meta_backup")
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.expectedMigrations), "7")
            XCTAssertEqual(try objectNames(db, names: V7MetaBackup.newTables), Set(V7MetaBackup.newTables))
            try SchemaMeta.verifyRequiredObjects(db, upTo: .v7_meta_backup)
        }
    }

    // MARK: - V7-02 v6 → v7 保留历史数据

    func testV702_IncrementalFromV6KeepsData() throws {
        let queue = try makeQueue("v702", upTo: .v6_character)
        try seedV6(queue)

        let snapshot = try queue.read { db in
            (
                try V3Chat.messageFingerprint(db),
                try V4Persona.itemFingerprint(db),
                try V7MetaBackup.attachmentFingerprint(db)
            )
        }

        try Migrations.makeMigrator(upTo: .v7_meta_backup).migrate(queue)

        try queue.read { db in
            XCTAssertEqual(try V3Chat.messageFingerprint(db), snapshot.0, "历史消息必须逐字不变")
            XCTAssertEqual(try V4Persona.itemFingerprint(db), snapshot.1, "人格条目必须逐字不变")
            XCTAssertEqual(try V7MetaBackup.attachmentFingerprint(db), snapshot.2, "历史附件必须逐字不变")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM attachments"), 1)
        }
    }

    // MARK: - V7-03 重复执行保护

    func testV703_RepeatedV7Rejected() throws {
        let queue = try makeQueue("v703", upTo: .v6_character)
        try seedV6(queue)
        try Migrations.makeMigrator(upTo: .v7_meta_backup).migrate(queue)

        XCTAssertThrowsError(try queue.write { db in try V7MetaBackup.migrate(db) })

        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM grdb_migrations"), 7)
        }
    }

    // MARK: - V7-04 记录表不得预置、历史附件不得被推断删除

    func testV704_MetaTablesStayEmpty() throws {
        let queue = try makeQueue("v704", upTo: .v6_character)
        try seedV6(queue)
        try Migrations.makeMigrator(upTo: .v7_meta_backup).migrate(queue)

        try queue.read { db in
            for table in V7MetaBackup.newTables {
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)"),
                    0,
                    "\(table) 不得预置数据"
                )
            }
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM attachments WHERE deleted_at IS NOT NULL OR deleted_reason IS NOT NULL"
                ),
                0,
                "历史附件不得被推断为已删除"
            )
        }
    }

    // MARK: - V7-05 附件新列与列顺序

    func testV705_AttachmentColumnsDefault() throws {
        let queue = try makeQueue("v705", upTo: .v6_character)
        try seedV6(queue)
        try Migrations.makeMigrator(upTo: .v7_meta_backup).migrate(queue)

        try queue.read { db in
            let row = try XCTUnwrap(
                Row.fetchOne(db, sql: "SELECT * FROM attachments WHERE id = 'a1'")
            )
            XCTAssertEqual(try row.decodeNil(forColumn: "deleted_at"), true)
            XCTAssertEqual(try row.decodeNil(forColumn: "deleted_reason"), true)

            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(attachments)").map {
                try $0.decode(String.self, forColumn: "name")
            }
            XCTAssertEqual(columns.count, V7MetaBackup.legacyAttachmentColumns.count + 2)
            XCTAssertEqual(Array(columns.suffix(2)), V7MetaBackup.newAttachmentColumns)
        }
    }

    // MARK: - V7-06 外键行为：删除备份不删除恢复记录

    func testV706_RestoreLogSurvivesBackupDeletion() throws {
        let queue = try makeQueue("v706", upTo: .v6_character)
        try seedV6(queue)
        try Migrations.makeMigrator(upTo: .v7_meta_backup).migrate(queue)

        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO backup_manifests (id, kind, scope, status, schema_version, file_name, rel_path, created_at)
            VALUES ('b1', 'manual', 'full', 'completed', 'v7_meta_backup', 'b1.zip', 'backup/b1.zip', 10)
            """)
            try db.execute(sql: """
            INSERT INTO restore_logs (id, backup_id, mode, status, started_at)
            VALUES ('r1', 'b1', 'new_copy', 'completed', 11)
            """)
        }

        try queue.write { db in
            try db.execute(sql: "DELETE FROM backup_manifests WHERE id = 'b1'")
        }

        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM restore_logs"), 1, "恢复记录不得被级联删除")
            XCTAssertEqual(
                try rowNil(db, sql: "SELECT backup_id FROM restore_logs WHERE id = 'r1'"),
                true,
                "备份被删除后 backup_id 应置空，保留历史事实"
            )
        }
    }

    private func rowNil(_ db: Database, sql: String) throws -> Bool {
        let row = try XCTUnwrap(Row.fetchOne(db, sql: sql))
        return try row.decodeNil(forColumnIndex: 0)
    }

    // MARK: - V7-07 必需对象门禁（61 项）

    func testV707_RequiredObjectsCountSixtyOne() throws {
        let database = try makeDatabase("v707")

        try database.dbQueue.read { db in
            try SchemaMeta.verifyRequiredObjects(db, upTo: .v7_meta_backup)

            let names = V7MetaBackup.newTables + V7MetaBackup.newIndexes
            XCTAssertEqual(try objectNames(db, names: names), Set(names))
        }
    }

    // MARK: - V7-08 previous_* 保留 v6 原值

    func testV708_PreviousKeysPreserveV6Values() throws {
        let queue = try makeQueue("v708", upTo: .v6_character)
        try seedV6(queue)

        let previous = try queue.read { db in
            (
                try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion),
                try SchemaMeta.value(db, key: SchemaMetaKey.migrationBatch),
                try SchemaMeta.value(db, key: SchemaMetaKey.migratedAt)
            )
        }
        XCTAssertEqual(previous.0, "v6_character")

        try Migrations.makeMigrator(upTo: .v7_meta_backup).migrate(queue)

        try queue.read { db in
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.previousSchemaVersion), previous.0)
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.previousMigrationBatch), previous.1)
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.previousMigratedAt), previous.2)
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion), "v7_meta_backup")
        }
    }

    // MARK: - V7-09 台账摘要独立复算

    func testV709_LedgerDigestRecomputedIndependently() throws {
        let database = try makeDatabase("v709")

        try database.dbQueue.read { db in
            let canonical = Array(MigrationLedger.canonicalIdentifiers.prefix(7))
            let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            XCTAssertEqual(Set(applied), Set(canonical))
            XCTAssertEqual(
                try SchemaMeta.value(db, key: SchemaMetaKey.ledgerDigest),
                SHA256.hash("migrations-v1\n" + canonical.joined(separator: "\n"))
            )
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.appliedPhase), "V2-P6")
        }
    }

    // MARK: - V7-10 哨兵不留残留

    func testV710_SentinelLeavesNoResidue() throws {
        let queue = try makeQueue("v710", upTo: .v6_character)
        try seedV6(queue)
        try Migrations.makeMigrator(upTo: .v7_meta_backup).migrate(queue)

        try queue.read { db in
            for table in V7MetaBackup.newTables {
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table) WHERE id LIKE '__v7_sentinel%'"),
                    0,
                    "\(table) 不得残留哨兵数据"
                )
            }
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT count(*) FROM attachments WHERE id LIKE '__v7_sentinel%'"),
                0
            )
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA quick_check"), "ok")
        }
    }
}

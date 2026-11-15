import XCTest
import GRDB
import DFCore
@testable import DFData

/// v12_diary_structure 迁移测试（V12-01 ~ V12-09）：日记结构化字段。
final class MigrationV12Tests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFV12-\(UUID().uuidString)", isDirectory: true)
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

    /// 造一份 v11 库里的历史日记（含版本快照与 FTS 索引）
    private func seedV11(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO diary_entries
                (id, entry_date, title, content, mood_code, source, generated_by,
                 is_user_edited, created_at, updated_at)
            VALUES ('d1', '2026-11-14', '旧日记', '她今天很安静', 'calm', 'manual', NULL, 1, 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO diary_entry_versions
                (id, diary_id, version, title, content, change_reason, changed_by, created_at)
            VALUES ('dv1', 'd1', 1, '旧日记', '她今天很安静', '初次记录', 'user', 1)
            """)
            try db.execute(
                sql: "INSERT INTO diary_fts (diary_id, text_bigram) VALUES ('d1', ?)",
                arguments: [V2Memory.bigram("旧日记 她今天很安静")]
            )
        }
    }

    func testV1201_FreshDatabaseMigratesToV12() throws {
        let queue = try makeQueue("v1201", upTo: .v1_phase1)
        try Migrations.makeMigrator(upTo: .v12_diary_structure).migrate(queue)

        try queue.read { db in
            let ledger = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            XCTAssertEqual(ledger.count, 12)
            XCTAssertEqual(
                try MigrationLedger.validatedPrefix(applied: ledger).last,
                MigrationID.v12_diary_structure.rawValue
            )
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion), "v12_diary_structure")
            XCTAssertEqual(try SchemaMeta.value(db, key: SchemaMetaKey.expectedMigrations), "12")
            try SchemaMeta.verifyRequiredObjects(db, upTo: .v12_diary_structure)
        }
    }

    func testV1202_IncrementalFromV11KeepsDiaryContent() throws {
        let queue = try makeQueue("v1202", upTo: .v11_local_models)
        try seedV11(queue)

        let before = try queue.read { db in
            (
                try V12DiaryStructure.diaryFingerprint(db),
                try V12DiaryStructure.versionFingerprint(db),
                try Int.fetchOne(db, sql: "SELECT count(*) FROM diary_entries") ?? -1
            )
        }
        try Migrations.makeMigrator(upTo: .v12_diary_structure).migrate(queue)

        try queue.read { db in
            XCTAssertEqual(try V12DiaryStructure.diaryFingerprint(db), before.0)
            XCTAssertEqual(try V12DiaryStructure.versionFingerprint(db), before.1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM diary_entries") ?? -1, before.2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM diary_entry_versions"), 1)
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT shared_experience, observation, feeling, relationship_change,
                       relationship_change_confirmed
                  FROM diary_entries WHERE id = 'd1'
                """
            )
            XCTAssertEqual(String.fromDatabaseValue(row?["shared_experience"] ?? .null), "")
            XCTAssertEqual(String.fromDatabaseValue(row?["relationship_change"] ?? .null), "")
            XCTAssertEqual(Int.fromDatabaseValue(row?["relationship_change_confirmed"] ?? .null), 0)
        }
    }

    func testV1203_RejectsRerun() throws {
        let queue = try makeQueue("v1203", upTo: .v12_diary_structure)
        XCTAssertThrowsError(try queue.write { db in
            try V12DiaryStructure.migrate(db)
        }) { error in
            XCTAssertTrue(String(describing: error).contains("v12_diary_structure"))
        }
    }

    func testV1204_NewColumnsExistOnBothTables() throws {
        let queue = try makeQueue("v1204", upTo: .v11_local_models)
        try Migrations.makeMigrator(upTo: .v12_diary_structure).migrate(queue)

        try queue.read { db in
            for table in ["diary_entries", "diary_entry_versions"] {
                let columns = Set(try String.fetchAll(
                    db,
                    sql: "SELECT name FROM pragma_table_info('\(table)')"
                ))
                for column in V12DiaryStructure.newColumns {
                    XCTAssertTrue(columns.contains(column), "\(table) 缺少列 \(column)")
                }
            }
        }
    }

    func testV1205_DoesNotFabricateStructuredContent() throws {
        let queue = try makeQueue("v1205", upTo: .v11_local_models)
        try seedV11(queue)
        try Migrations.makeMigrator(upTo: .v12_diary_structure).migrate(queue)

        try queue.read { db in
            let fabricated = try Int.fetchOne(
                db,
                sql: """
                SELECT count(*) FROM diary_entries
                 WHERE shared_experience <> '' OR observation <> ''
                    OR feeling <> '' OR relationship_change <> ''
                    OR relationship_change_confirmed <> 0
                """
            )
            XCTAssertEqual(fabricated, 0, "历史日记不得被补写结构化内容")
        }
    }

    func testV1206_RelationIndexExistsAndIsQueryable() throws {
        let queue = try makeQueue("v1206", upTo: .v12_diary_structure)
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO diary_entries (id, entry_date, content, created_at, updated_at)
            VALUES ('d1', '2026-11-15', '正文', 1, 1)
            """)
            try db.execute(sql: """
            UPDATE diary_entries
               SET relationship_change = '更亲近了一些',
                   relationship_change_confirmed = 0
             WHERE id = 'd1'
            """)
        }
        try queue.read { db in
            let exists = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM sqlite_master WHERE type='index' AND name='ix_diary_entries_relation'"
            )
            XCTAssertEqual(exists, 1)
            let pending = try Int.fetchOne(
                db,
                sql: """
                SELECT count(*) FROM diary_entries
                 WHERE relationship_change_confirmed = 0 AND relationship_change <> ''
                """
            )
            XCTAssertEqual(pending, 1, "待确认的关系变化必须可查")
        }
    }

    func testV1207_SentinelIsCleaned() throws {
        let queue = try makeQueue("v1207", upTo: .v11_local_models)
        try seedV11(queue)
        try Migrations.makeMigrator(upTo: .v12_diary_structure).migrate(queue)

        try queue.read { db in
            let sentinels = try Int.fetchOne(
                db,
                sql: """
                SELECT (SELECT count(*) FROM diary_entries WHERE id LIKE '__v12_sentinel%')
                     + (SELECT count(*) FROM diary_entry_versions WHERE id LIKE '__v12_sentinel%')
                """
            )
            XCTAssertEqual(sentinels, 0, "哨兵数据必须在迁移结束前清理")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM diary_entries"), 1)
        }
    }

    func testV1208_DiaryFTSIsUntouched() throws {
        let queue = try makeQueue("v1208", upTo: .v11_local_models)
        try seedV11(queue)
        let before = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM diary_fts") ?? -1
        }
        try Migrations.makeMigrator(upTo: .v12_diary_structure).migrate(queue)

        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM diary_fts"), before)
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA quick_check")?.lowercased(), "ok")
        }
    }

    func testV1209_PreviousMetaKeys() throws {
        let queue = try makeQueue("v1209", upTo: .v11_local_models)
        try Migrations.makeMigrator(upTo: .v12_diary_structure).migrate(queue)
        try queue.read { db in
            XCTAssertEqual(
                try SchemaMeta.value(db, key: SchemaMetaKey.previousSchemaVersion),
                "v11_local_models"
            )
            XCTAssertNotNil(try SchemaMeta.value(db, key: SchemaMetaKey.previousMigrationBatch))
            XCTAssertNotNil(try SchemaMeta.value(db, key: SchemaMetaKey.previousMigratedAt))
        }
    }
}

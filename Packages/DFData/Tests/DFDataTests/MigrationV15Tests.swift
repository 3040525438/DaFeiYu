import XCTest
import GRDB
import DFCore
@testable import DFData

/// v15（表情包）迁移安全
final class MigrationV15Tests: XCTestCase {
    func testLatestIsV15() {
        XCTAssertEqual(Migrations.latest, .v15_stickers)
        XCTAssertEqual(MigrationID.allCases.last, .v15_stickers)
    }

    func testMigrationCreatesStickerObjectsAndPassesGate() async throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue)

        try await queue.read { db in
            for table in ["sticker_packs", "stickers", "sticker_usage"] {
                XCTAssertTrue(try db.tableExists(table), "缺少表 \(table)")
            }
            let indexCount = try Int.fetchOne(
                db,
                sql: """
                SELECT count(*) FROM sqlite_master
                 WHERE type = 'index'
                   AND name IN ('ix_stickers_pack', 'ix_stickers_kind', 'ix_stickers_favorite',
                                'ix_stickers_alive', 'ix_sticker_usage_time')
                """
            ) ?? 0
            XCTAssertEqual(indexCount, 5)
            XCTAssertEqual(
                try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion),
                MigrationID.v15_stickers.rawValue
            )
            try SchemaMeta.verifyRequiredObjects(db)
        }
    }

    func testUpgradeKeepsExistingRowsAndLeavesNoSeedData() async throws {
        let queue = try DatabaseQueue()
        try Migrations.makeMigrator(upTo: .v14_message_organization).migrate(queue)

        try await queue.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '主会话', 'main', 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
            VALUES ('m1', 'u1', 'c1', 'user', 'text', '升级前的消息', 'sent', 'user', 1)
            """)
            try db.execute(sql: """
            INSERT INTO attachments (id, sha256, kind, rel_path, byte_size, mime, created_at)
            VALUES ('a1', 'sha-a1', 'image', 'aa/bb/sha-a1.png', 10, 'image/png', 1)
            """)
        }

        try Migrations.migrator.migrate(queue)

        try await queue.read { db in
            let text = try String.fetchOne(db, sql: "SELECT text FROM messages WHERE id = 'm1'")
            XCTAssertEqual(text, "升级前的消息")
            let attachment = try Int.fetchOne(db, sql: "SELECT count(*) FROM attachments WHERE id = 'a1'")
            XCTAssertEqual(attachment, 1)
            for table in ["sticker_packs", "stickers", "sticker_usage"] {
                let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)")
                XCTAssertEqual(count, 0, "\(table) 不得在迁移中预置数据")
            }
            try SchemaMeta.verifyRequiredObjects(db)
        }
    }

    func testStickerUsagePrimaryKeyRejectsDuplicatePair() async throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue)

        try await queue.write { db in
            try db.execute(sql: """
            INSERT INTO stickers (id, pack_id, kind, name, tags, emoji, attachment_id, semantics,
                                  semantics_source, is_favorite, created_at, updated_at, deleted_at)
            VALUES ('s1', NULL, 'emoji', '微笑', '', '😊', NULL, '', 'catalog', 0, 1, 1, NULL)
            """)
            try db.execute(sql: """
            INSERT INTO sticker_usage (sticker_id, used_at, message_id) VALUES ('s1', 100, NULL)
            """)
            XCTAssertThrowsError(
                try db.execute(sql: """
                INSERT INTO sticker_usage (sticker_id, used_at, message_id) VALUES ('s1', 100, NULL)
                """),
                "同一表情同一毫秒只能有一条使用记录"
            )
        }
    }

    /// 表情附件被删除时，表情索引不得跟着消失（只置空引用）
    func testAttachmentDeleteSetsStickerAttachmentToNull() async throws {
        // 外键需要 PRAGMA foreign_keys = ON，只有 AppDatabase 的配置会开启
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFStickerFK-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase(paths: DatabasePaths(root: root))

        try await database.write { db in
            try db.execute(sql: """
            INSERT INTO attachments (id, sha256, kind, rel_path, byte_size, mime, created_at)
            VALUES ('a1', 'sha-a1', 'image', 'aa/bb/sha-a1.png', 10, 'image/png', 1)
            """)
            try db.execute(sql: """
            INSERT INTO stickers (id, pack_id, kind, name, tags, emoji, attachment_id, semantics,
                                  semantics_source, is_favorite, created_at, updated_at, deleted_at)
            VALUES ('s1', NULL, 'static', '拍桌', '', NULL, 'a1', '', 'none', 0, 1, 1, NULL)
            """)
            try db.execute(sql: "DELETE FROM attachments WHERE id = 'a1'")
            let attachmentID = try String.fetchOne(db, sql: "SELECT attachment_id FROM stickers WHERE id = 's1'")
            XCTAssertNil(attachmentID, "附件删除后表情索引应保留、引用置空")
        }
    }
}

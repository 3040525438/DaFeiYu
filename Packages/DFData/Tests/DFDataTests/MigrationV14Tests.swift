import XCTest
import GRDB
import DFCore
@testable import DFData

/// v14（D26 消息整理）迁移安全
final class MigrationV14Tests: XCTestCase {
    func testLatestIsV14() {
        XCTAssertEqual(Migrations.latest, .v14_message_organization)
        XCTAssertEqual(MigrationID.allCases.last, .v14_message_organization)
    }

    func testMigrationCreatesOrganizationObjectsAndPassesGate() async throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue)

        try await queue.read { db in
            XCTAssertTrue(try db.tableExists("message_tags"))
            let indexCount = try Int.fetchOne(
                db,
                sql: """
                SELECT count(*) FROM sqlite_master
                 WHERE type = 'index'
                   AND name IN ('ux_message_tags', 'ix_message_tags_tag', 'ix_messages_important')
                """
            ) ?? 0
            XCTAssertEqual(indexCount, 3)
            let columns = try db.columns(in: "messages").map(\.name)
            XCTAssertTrue(columns.contains("is_important"))
            XCTAssertTrue(columns.contains("important_at"))
            XCTAssertEqual(
                try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion),
                MigrationID.v14_message_organization.rawValue
            )
            try SchemaMeta.verifyRequiredObjects(db)
        }
    }

    func testUpgradeKeepsExistingRowsAndDefaultsToNotImportant() async throws {
        let queue = try DatabaseQueue()
        try Migrations.makeMigrator(upTo: .v13_cost_ledger).migrate(queue)

        try await queue.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '主会话', 'main', 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
            VALUES ('m1', 'u1', 'c1', 'user', 'text', '升级前的消息', 'sent', 'user', 1)
            """)
        }

        try Migrations.migrator.migrate(queue)

        try await queue.read { db in
            let row = try XCTUnwrap(
                try Row.fetchOne(db, sql: "SELECT text, is_important, important_at FROM messages WHERE id = 'm1'")
            )
            XCTAssertEqual(try row.decode(String.self, forColumn: "text"), "升级前的消息")
            XCTAssertEqual(Int.fromDatabaseValue(row["is_important"]), 0, "历史消息不得被标成重要")
            XCTAssertNil(Int64.fromDatabaseValue(row["important_at"]))
            let tags = try Int.fetchOne(db, sql: "SELECT count(*) FROM message_tags")
            XCTAssertEqual(tags, 0, "升级不得留下哨兵标签")
            try SchemaMeta.verifyRequiredObjects(db)
        }
    }

    func testTagUniqueConstraintRejectsDuplicates() async throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue)

        try await queue.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '主会话', 'main', 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
            VALUES ('m1', 'u1', 'c1', 'user', 'text', '正文', 'sent', 'user', 1)
            """)
            try db.execute(sql: """
            INSERT INTO message_tags (id, message_id, tag, created_at) VALUES ('t1', 'm1', '摄影', 1)
            """)
            XCTAssertThrowsError(
                try db.execute(sql: """
                INSERT INTO message_tags (id, message_id, tag, created_at) VALUES ('t2', 'm1', '摄影', 2)
                """),
                "同一消息同一标签必须唯一"
            )
        }
    }
}

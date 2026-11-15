import XCTest
import GRDB
import DFCore
@testable import DFData

/// v13（D10 成本台账）迁移安全
final class MigrationV13Tests: XCTestCase {
    func testLatestIsV13() {
        XCTAssertEqual(Migrations.latest, .v13_cost_ledger)
        XCTAssertEqual(MigrationID.allCases.last, .v13_cost_ledger)
    }

    func testMigrationCreatesCostLedgerAndPassesGate() async throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue)

        try await queue.read { db in
            XCTAssertTrue(try db.tableExists("cost_ledger"))
            let indexCount = try Int.fetchOne(
                db,
                sql: """
                SELECT count(*) FROM sqlite_master
                 WHERE type = 'index' AND name IN ('ix_cost_ledger_day', 'ix_cost_ledger_created')
                """
            ) ?? 0
            XCTAssertEqual(indexCount, 2)
            XCTAssertEqual(
                try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion),
                MigrationID.v13_cost_ledger.rawValue
            )
            try SchemaMeta.verifyRequiredObjects(db)
        }
    }

    func testUpgradeKeepsExistingRows() async throws {
        let queue = try DatabaseQueue()
        try Migrations.makeMigrator(upTo: .v12_diary_structure).migrate(queue)

        try await queue.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '主会话', 'main', 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
            VALUES ('m1', 'u1', 'c1', 'user', 'text', '升级前消息', 'sent', 'local', 1)
            """)
        }

        try Migrations.migrator.migrate(queue)

        try await queue.read { db in
            let messages = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages")
            XCTAssertEqual(messages, 1)
            let text = try String.fetchOne(db, sql: "SELECT text FROM messages WHERE id = 'm1'")
            XCTAssertEqual(text, "升级前消息")
            let ledgerEmpty = try Int.fetchOne(db, sql: "SELECT count(*) FROM cost_ledger")
            XCTAssertEqual(ledgerEmpty, 0, "升级不得留下哨兵记录")
            try SchemaMeta.verifyRequiredObjects(db)
        }
    }

    func testCostLedgerRejectsZeroCostForUnavailable() async throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue)

        try await queue.write { db in
            XCTAssertThrowsError(
                try db.execute(sql: """
                INSERT INTO cost_ledger
                    (id, day_key, scope, provider, model_id, status, cost_kind, cost_yuan, created_at)
                VALUES ('bad', '2026-11-15', 'chat', 'p', 'm', 'settled', 'unavailable', 0, 1)
                """),
                "unavailable 必须写 NULL，禁止用 0 冒充未知费用"
            )
        }
    }
}

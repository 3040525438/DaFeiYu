import XCTest
import GRDB
import DFCore
@testable import DFData

/// D59：用户数据导出——白名单、凭据剔除、空库与落盘。
final class UserDataExporterTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
    }

    override func tearDownWithError() throws {
        database = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func seed() async throws {
        try await database.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '主会话', 'main', 1000, 1000)
            """)
            try db.execute(sql: """
            INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
            VALUES ('m1', 'uuid-m1', 'c1', 'user', 'text', '今天想早点睡', 'sent', 'user', 1100)
            """)
            // 设置表可能含凭据，必须整表排除
            try db.execute(sql: """
            INSERT INTO settings (key, value)
            VALUES ('llm.api_key', 'sk-should-not-export')
            """)
        }
    }

    private func loadJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func testExportWritesWhitelistedTablesOnly() async throws {
        try await seed()
        let exporter = UserDataExporter(database: database)
        let summary = try await exporter.export()

        XCTAssertTrue(FileManager.default.fileExists(atPath: summary.url.path))
        XCTAssertGreaterThan(summary.byteSize, 0)
        XCTAssertEqual(summary.counts["conversations"], 1)
        XCTAssertEqual(summary.counts["messages"], 1)
        XCTAssertEqual(summary.totalRows, summary.counts.values.reduce(0, +))

        let json = try loadJSON(summary.url)
        XCTAssertEqual(json["format"] as? String, UserDataExporter.format)
        XCTAssertEqual(json["schemaVersion"] as? String, Migrations.latest.rawValue)

        let tables = json["tables"] as? [String: Any]
        XCTAssertNotNil(tables?["conversations"])
        XCTAssertNotNil(tables?["messages"])
        XCTAssertNil(tables?["settings"], "settings 整表不得导出")
        XCTAssertNil(tables?["local_models"], "本地模型表不得导出")

        let messages = tables?["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.first?["text"] as? String, "今天想早点睡")
    }

    func testExportDoesNotContainCredentialValues() async throws {
        try await seed()
        let summary = try await UserDataExporter(database: database).export()
        let content = try String(contentsOf: summary.url, encoding: .utf8)
        XCTAssertFalse(content.contains("sk-should-not-export"))
    }

    func testExportToCustomDirectory() async throws {
        try await seed()
        let target = root.appendingPathComponent("Chosen", isDirectory: true)
        let summary = try await UserDataExporter(database: database).export(to: target)
        XCTAssertEqual(summary.url.deletingLastPathComponent().lastPathComponent, "Chosen")
        XCTAssertTrue(FileManager.default.fileExists(atPath: summary.url.path))
    }

    func testEmptyDatabaseThrowsNothingToExport() async {
        let exporter = UserDataExporter(database: database)
        do {
            _ = try await exporter.export()
            XCTFail("空库应拒绝导出")
        } catch {
            XCTAssertEqual(error as? UserDataExportError, .nothingToExport)
        }
    }

    func testExportIsReadOnly() async throws {
        try await seed()
        _ = try await UserDataExporter(database: database).export()
        let count = try database.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages")
        }
        XCTAssertEqual(count, 1)
        XCTAssertFalse(database.isReadOnly, "导出不得让数据库进入只读状态")
    }

    func testExcludedColumnNamesCoverCredentials() {
        for name in ["api_key", "token", "passcode_hash", "secret"] {
            XCTAssertTrue(UserDataExporter.excludedColumnNames.contains(name))
        }
    }
}

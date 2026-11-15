import XCTest
import GRDB
import DFCore
@testable import DFData

/// D56：日期跳转分页（`page(in:around:limit:)`）基于真实 SQLite。
final class MessageDateJumpTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFDateJump-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(paths: DatabasePaths(root: root.appendingPathComponent("db", isDirectory: true)))
    }

    private func seedConversation(_ database: AppDatabase) async throws {
        try await database.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '大肥鱼', 'main', 1, 1)
            """)
        }
    }

    private func insert(
        _ database: AppDatabase,
        id: String,
        createdAt: Int64,
        deleted: Bool = false
    ) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin,
                                      created_at, deleted_at, group_id, seq_in_group)
                VALUES (?, ?, 'c1', 'user', 'text', ?, 'sent', 'user', ?, ?, NULL, NULL)
                """,
                arguments: [
                    id, "uuid-\(id)", "消息 \(id)", createdAt, deleted ? createdAt + 1 : nil
                ]
            )
        }
    }

    func testAroundReturnsPageEndingAtTargetTime() async throws {
        let database = try makeDatabase()
        try await seedConversation(database)
        // 每 10 分钟一条，共 10 条
        for index in 0..<10 {
            try await insert(database, id: "m\(index)", createdAt: Int64(index) * 600_000)
        }

        let repository = GRDBMessageRepository(database: database)
        // 目标在中段（第 5 条的时间点），取 3 条一页
        let page = try await repository.page(in: "c1", around: 5 * 600_000, limit: 3)

        XCTAssertEqual(page.items.map(\.id), ["m3", "m4", "m5"])
        XCTAssertTrue(page.hasMore, "更早还有消息")
        XCTAssertNotNil(page.nextCursor)
    }

    func testAroundBeforeEarliestReturnsEmpty() async throws {
        let database = try makeDatabase()
        try await seedConversation(database)
        for index in 0..<3 {
            try await insert(database, id: "m\(index)", createdAt: Int64(index + 1) * 600_000)
        }
        let repository = GRDBMessageRepository(database: database)
        let page = try await repository.page(in: "c1", around: 0, limit: 10)
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertFalse(page.hasMore)
    }

    func testAroundSkipsSoftDeleted() async throws {
        let database = try makeDatabase()
        try await seedConversation(database)
        try await insert(database, id: "m0", createdAt: 600_000)
        try await insert(database, id: "m1", createdAt: 1_200_000, deleted: true)
        try await insert(database, id: "m2", createdAt: 1_800_000)

        let repository = GRDBMessageRepository(database: database)
        let page = try await repository.page(in: "c1", around: 1_500_000, limit: 10)
        XCTAssertEqual(page.items.map(\.id), ["m0"], "软删消息不占返回条数")
    }

    func testAroundCursorCanPageFurtherBack() async throws {
        let database = try makeDatabase()
        try await seedConversation(database)
        for index in 0..<6 {
            try await insert(database, id: "m\(index)", createdAt: Int64(index) * 600_000)
        }
        let repository = GRDBMessageRepository(database: database)
        let first = try await repository.page(in: "c1", around: 4 * 600_000, limit: 2)
        XCTAssertEqual(first.items.map(\.id), ["m3", "m4"])
        let older = try await repository.page(in: "c1", before: first.nextCursor, limit: 2)
        XCTAssertEqual(older.items.map(\.id), ["m1", "m2"])
    }
}

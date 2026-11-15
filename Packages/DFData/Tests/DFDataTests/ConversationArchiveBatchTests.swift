import XCTest
import GRDB
import DFCore
@testable import DFData

/// D51：批量归档 / 取消归档（main 保护、幂等计数、归档仍可检索）。
final class ConversationArchiveBatchTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var repo: GRDBConversationAdminRepository!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFArchiveBatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        repo = GRDBConversationAdminRepository(database: database)
        try await seed()
    }

    override func tearDownWithError() throws {
        repo = nil
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
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c2', '摄影', 'chat', 2000, 2000)
            """)
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at, archived_at)
            VALUES ('c3', '旧对话', 'chat', 3000, 3000, 3100)
            """)
            try db.execute(sql: """
            INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
            VALUES ('m1', 'uuid-m1', 'c2', 'user', 'text', '摄影笔记第二篇', 'sent', 'user', 2500)
            """)
        }
        _ = try await GRDBChatSearchRepository(database: database).rebuildIndex(conversationID: nil)
    }

    private func archivedAt(_ id: String) throws -> Int64? {
        try database.dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT archived_at FROM conversations WHERE id = ?",
                arguments: [id]
            )
            return row.flatMap { Int64.fromDatabaseValue($0["archived_at"]) }
        }
    }

    func testBatchArchiveSkipsMainAndIsIdempotent() async throws {
        let result = try await repo.setArchivedBatch(
            ids: ["c1", "c2", "c3", "missing"],
            archived: true,
            at: 9000
        )
        XCTAssertEqual(result.affected, 1, "c2 状态变化；c3 已归档不重复计数")
        XCTAssertEqual(result.skippedProtected, 1, "main 会话不可归档")
        XCTAssertEqual(result.notFound, 1)
        XCTAssertNil(try archivedAt("c1"))
        XCTAssertEqual(try archivedAt("c2"), 9000)
        XCTAssertEqual(try archivedAt("c3"), 3100, "已归档会话的归档时间不得被覆盖")

        let again = try await repo.setArchivedBatch(ids: ["c2"], archived: true, at: 9500)
        XCTAssertEqual(again.affected, 0, "重复归档必须幂等")
        XCTAssertEqual(try archivedAt("c2"), 9000)
    }

    func testBatchUnarchiveRestoresActiveList() async throws {
        let result = try await repo.setArchivedBatch(ids: ["c3"], archived: false, at: 9000)
        XCTAssertEqual(result.affected, 1)
        XCTAssertNil(try archivedAt("c3"))

        let active = try await repo.list(.active).map(\.id)
        XCTAssertTrue(active.contains("c3"))
    }

    func testArchivedConversationStillSearchable() async throws {
        _ = try await repo.setArchivedBatch(ids: ["c2"], archived: true, at: 9000)

        // 归档不删数据：会话内检索仍能命中
        let hits = try await GRDBChatSearchRepository(database: database)
            .search(query: "摄影", conversationID: "c2", limit: 10)
        XCTAssertEqual(hits.map(\.messageID), ["m1"])

        // 统一检索同样不受归档影响
        let unified = try await GRDBUnifiedSearchRepository(database: database)
            .search(query: "摄影", domains: [.message], limitPerDomain: 10)
        XCTAssertEqual(unified.map(\.messageID), ["m1"])
    }

    func testEmptyBatchIsNoOp() async throws {
        let result = try await repo.setArchivedBatch(ids: [], archived: true, at: 9000)
        XCTAssertEqual(result.affected, 0)
        XCTAssertEqual(result.skippedProtected, 0)
        XCTAssertEqual(result.notFound, 0)
    }
}

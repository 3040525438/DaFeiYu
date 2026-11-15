import XCTest
import GRDB
import DFCore
@testable import DFData

/// D36 / D37：当前启用角色的读取与兜底创建。
final class CharacterProfileServiceTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var service: CharacterProfileService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFCharacterProfile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        service = CharacterProfileService(database: database, now: { 2_000 })
    }

    override func tearDownWithError() throws {
        service = nil
        database = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func insert(
        id: String,
        isActive: Bool,
        sort: Int = 0,
        createdAt: Int64 = 1_000
    ) async throws {
        try await database.write { db in
            try db.execute(sql: """
            INSERT INTO characters (id, name, kind, summary, is_active, sort, created_at, updated_at)
            VALUES (?, '自定义', 'custom', '', ?, ?, ?, ?)
            """, arguments: [id, isActive ? 1 : 0, sort, createdAt, createdAt])
        }
    }

    private func characterCount() async throws -> Int {
        try await database.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM characters") ?? 0
        }
    }

    private func activeCount() async throws -> Int {
        try await database.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM characters WHERE is_active = 1") ?? 0
        }
    }

    func testCreatesDefaultCharacterWhenEmpty() async throws {
        let id = try await service.activeCharacterID()

        XCTAssertEqual(id, CharacterProfileService.defaultCharacterID)
        XCTAssertEqual(try await characterCount(), 1)
        XCTAssertEqual(try await activeCount(), 1)

        let name = try await database.dbQueue.read { db -> String? in
            try String.fetchOne(db, sql: "SELECT name FROM characters WHERE id = ?", arguments: [id])
        }
        XCTAssertEqual(name, CharacterProfileService.defaultCharacterName)
    }

    func testIsIdempotent() async throws {
        let first = try await service.activeCharacterID()
        let second = try await service.activeCharacterID()
        let third = try await service.ensureDefaultCharacter()

        XCTAssertEqual(first, second)
        XCTAssertEqual(second, third)
        XCTAssertEqual(try await characterCount(), 1)
    }

    func testExistingActiveCharacterIsRespected() async throws {
        try await insert(id: "custom-1", isActive: true)
        let id = try await service.activeCharacterID()

        XCTAssertEqual(id, "custom-1")
        XCTAssertEqual(try await characterCount(), 1)
    }

    func testInactiveCharacterIsActivatedInsteadOfCreatingNew() async throws {
        try await insert(id: "custom-1", isActive: false)
        let id = try await service.activeCharacterID()

        XCTAssertEqual(id, "custom-1")
        XCTAssertEqual(try await characterCount(), 1)
        XCTAssertEqual(try await activeCount(), 1)
    }

    func testOnlyOneCharacterStaysActive() async throws {
        try await insert(id: "a", isActive: true, sort: 0, createdAt: 1_000)
        try await insert(id: "b", isActive: true, sort: 1, createdAt: 1_001)

        let id = try await service.ensureDefaultCharacter()

        XCTAssertEqual(id, "a", "按 sort / created_at 取最早的启用角色")
        XCTAssertEqual(try await activeCount(), 1, "不得出现两个启用角色")
    }
}

import XCTest
import GRDB
import DFCore
@testable import DFData

/// D26：收藏 / 重要标记 / 分类标签（含批量与边界）。
final class MessageOrganizationTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var repo: GRDBMessageOrganizationRepository!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFOrg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        repo = GRDBMessageOrganizationRepository(database: database)
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
            VALUES ('c1', '主会话', 'main', 1, 1)
            """)
            for (id, text, millis, deletedAt) in [
                ("m1", "今天去看了摄影展", Int64(1000), Int64?.none),
                ("m2", "拍到一只橘猫", Int64(2000), Int64?.none),
                ("m3", "已删除的消息", Int64(3000), Int64(4000))
            ] {
                try db.execute(
                    sql: """
                    INSERT INTO messages
                        (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at, deleted_at)
                    VALUES (?, ?, 'c1', 'user', 'text', ?, 'sent', 'user', ?, ?)
                    """,
                    arguments: [id, "uuid-\(id)", text, millis, deletedAt]
                )
            }
        }
    }

    private func messageRow(_ id: String) throws -> Row? {
        try database.dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM messages WHERE id = ?", arguments: [id])
        }
    }

    private func count(_ table: String) throws -> Int {
        try database.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? -1
        }
    }

    // MARK: - 重要标记

    func testSetImportantTogglesFlagAndTimestamp() async throws {
        try await repo.setImportant(id: "m1", isImportant: true, at: 5000)
        var row = try XCTUnwrap(try messageRow("m1"))
        XCTAssertEqual(Int.fromDatabaseValue(row["is_important"]), 1)
        XCTAssertEqual(Int64.fromDatabaseValue(row["important_at"]), 5000)

        try await repo.setImportant(id: "m1", isImportant: false, at: 6000)
        row = try XCTUnwrap(try messageRow("m1"))
        XCTAssertEqual(Int.fromDatabaseValue(row["is_important"]), 0)
        XCTAssertNil(Int64.fromDatabaseValue(row["important_at"]))
    }

    func testSetImportantRejectsMissingAndDeleted() async throws {
        do {
            try await repo.setImportant(id: "missing", isImportant: true, at: 1)
            XCTFail("不存在的消息必须报错")
        } catch let error as MessageOrganizationError {
            XCTAssertEqual(error, .notFound)
        }

        do {
            try await repo.setImportant(id: "m3", isImportant: true, at: 1)
            XCTFail("已删除的消息必须报错")
        } catch let error as MessageOrganizationError {
            XCTAssertEqual(error, .deleted)
        }
    }

    // MARK: - 批量收藏

    func testFavoriteBatchCountsOnlyRealChanges() async throws {
        let first = try await repo.setFavoriteBatch(ids: ["m1", "m1", "m2"], isFavorite: true, at: 5000)
        XCTAssertEqual(first, 2, "重复 id 只计一次")

        let again = try await repo.setFavoriteBatch(ids: ["m1", "m2"], isFavorite: true, at: 6000)
        XCTAssertEqual(again, 0, "重复收藏不重复计数")

        let row = try XCTUnwrap(try messageRow("m1"))
        XCTAssertEqual(Int.fromDatabaseValue(row["is_favorite"]), 1)
        XCTAssertEqual(Int64.fromDatabaseValue(row["favorited_at"]), 5000, "时间不应被无变化操作覆盖")

        let removed = try await repo.setFavoriteBatch(ids: ["m1", "m2"], isFavorite: false, at: 7000)
        XCTAssertEqual(removed, 2)
    }

    func testFavoriteBatchSkipsDeletedMessages() async throws {
        let affected = try await repo.setFavoriteBatch(ids: ["m3"], isFavorite: true, at: 5000)
        XCTAssertEqual(affected, 0)
    }

    // MARK: - 标签

    func testAddTagNormalizesAndDeduplicates() async throws {
        let added = try await repo.addTag("  #摄影  日常 ", to: ["m1", "m2"], at: 5000)
        XCTAssertEqual(added, 2)

        let repeated = try await repo.addTag("摄影 日常", to: ["m1"], at: 6000)
        XCTAssertEqual(repeated, 0, "同一消息同一标签不得重复写入")

        let tags = try await repo.tags(ofMessage: "m1")
        XCTAssertEqual(tags, ["摄影 日常"])
    }

    func testAddTagSkipsDeletedMessages() async throws {
        let added = try await repo.addTag("归档", to: ["m3"], at: 5000)
        XCTAssertEqual(added, 0)
        XCTAssertEqual(try count("message_tags"), 0)
    }

    func testEmptyTagRejected() async throws {
        do {
            _ = try await repo.addTag("  #  ", to: ["m1"], at: 5000)
            XCTFail("空标签必须拒绝")
        } catch let error as MessageOrganizationError {
            XCTAssertEqual(error, .emptyTag)
        }
    }

    func testRemoveTagOnlyAffectsGivenMessages() async throws {
        _ = try await repo.addTag("旅行", to: ["m1", "m2"], at: 5000)
        let removed = try await repo.removeTag("旅行", from: ["m1"])
        XCTAssertEqual(removed, 1)

        let firstTags = try await repo.tags(ofMessage: "m1")
        let secondTags = try await repo.tags(ofMessage: "m2")
        XCTAssertEqual(firstTags, [])
        XCTAssertEqual(secondTags, ["旅行"])
    }

    func testTagSummaryOrdersByUsageThenName() async throws {
        _ = try await repo.addTag("旅行", to: ["m1", "m2"], at: 5000)
        _ = try await repo.addTag("摄影", to: ["m1"], at: 5000)

        let summary = try await repo.tagSummary()
        XCTAssertEqual(summary.map(\.tag), ["旅行", "摄影"])
        XCTAssertEqual(summary.map(\.count), [2, 1])
    }

    // MARK: - 列表

    func testMessageIDsFilters() async throws {
        _ = try await repo.setFavoriteBatch(ids: ["m1"], isFavorite: true, at: 5000)
        try await repo.setImportant(id: "m2", isImportant: true, at: 5000)
        _ = try await repo.addTag("旅行", to: ["m1"], at: 5000)

        let favorites = try await repo.messageIDs(filter: .favorite, limit: 10, offset: 0)
        let importants = try await repo.messageIDs(filter: .important, limit: 10, offset: 0)
        let tagged = try await repo.messageIDs(filter: .tagged("旅行"), limit: 10, offset: 0)
        let taggedWithHash = try await repo.messageIDs(filter: .tagged("#旅行"), limit: 10, offset: 0)
        let all = try await repo.messageIDs(filter: .all, limit: 10, offset: 0)
        let paged = try await repo.messageIDs(filter: .all, limit: 1, offset: 1)

        XCTAssertEqual(favorites, ["m1"])
        XCTAssertEqual(importants, ["m2"])
        XCTAssertEqual(tagged, ["m1"])
        XCTAssertEqual(taggedWithHash, ["m1"])
        // 已删除消息不出现；按创建时间倒序
        XCTAssertEqual(all, ["m2", "m1"])
        XCTAssertEqual(paged, ["m1"])
    }

    func testTaggedFilterWithEmptyTagReturnsEmpty() async throws {
        let result = try await repo.messageIDs(filter: .tagged("   "), limit: 10, offset: 0)
        XCTAssertEqual(result, [])
    }

    // MARK: - 边界

    func testOrganizationNeverCreatesMemories() async throws {
        _ = try await repo.setFavoriteBatch(ids: ["m1", "m2"], isFavorite: true, at: 5000)
        try await repo.setImportant(id: "m1", isImportant: true, at: 5000)
        _ = try await repo.addTag("旅行", to: ["m1"], at: 5000)

        XCTAssertEqual(try count("memories"), 0, "收藏/重要/标签都不得生成记忆（D26）")
        XCTAssertEqual(try count("memory_fts"), 0)
    }

    func testIdempotentOperationsDoNotDuplicateTagRows() async throws {
        _ = try await repo.addTag("旅行", to: ["m1"], at: 5000)
        _ = try await repo.addTag("旅行", to: ["m1"], at: 6000)
        XCTAssertEqual(try count("message_tags"), 1)
    }

    // MARK: - 标签全局重命名（I-01）

    func testRenameTagUpdatesEveryMessage() async throws {
        _ = try await repo.addTag("旅行", to: ["m1", "m2"], at: 5000)
        let renamed = try await repo.renameTag("旅行", to: "出游", at: 7000)
        XCTAssertEqual(renamed, 2)
        let tagsM1 = try await repo.tags(ofMessage: "m1")
        let tagsM2 = try await repo.tags(ofMessage: "m2")
        XCTAssertEqual(tagsM1, ["出游"])
        XCTAssertEqual(tagsM2, ["出游"])
        let summary = try await repo.tagSummary()
        XCTAssertEqual(summary.map(\.tag), ["出游"])
        XCTAssertEqual(summary.first?.count, 2)
    }

    func testRenameTagNormalizesBothSides() async throws {
        _ = try await repo.addTag("旅行", to: ["m1"], at: 5000)
        let renamed = try await repo.renameTag("  #旅行  ", to: "  出   游 ", at: 7000)
        XCTAssertEqual(renamed, 1)
        let tags = try await repo.tags(ofMessage: "m1")
        XCTAssertEqual(tags, ["出 游"])
    }

    func testRenameTagMergesIntoExistingTagWithoutDuplicates() async throws {
        _ = try await repo.addTag("旅行", to: ["m1", "m2"], at: 5000)
        _ = try await repo.addTag("出游", to: ["m1"], at: 6000)
        _ = try await repo.renameTag("旅行", to: "出游", at: 7000)
        let tagsM1 = try await repo.tags(ofMessage: "m1")
        let tagsM2 = try await repo.tags(ofMessage: "m2")
        XCTAssertEqual(tagsM1, ["出游"], "已存在同名标签时只保留一行")
        XCTAssertEqual(tagsM2, ["出游"])
        XCTAssertEqual(try count("message_tags"), 2)
    }

    func testRenameTagRejectsInvalidTarget() async throws {
        _ = try await repo.addTag("旅行", to: ["m1"], at: 5000)
        do {
            _ = try await repo.renameTag("旅行", to: "   ", at: 7000)
            XCTFail("空标签应被拒绝")
        } catch let error as MessageOrganizationError {
            XCTAssertEqual(error, .emptyTag)
        }
        let tooLong = String(repeating: "长", count: MessageTagRules.maxLength + 1)
        do {
            _ = try await repo.renameTag("旅行", to: tooLong, at: 7000)
            XCTFail("超长标签应被拒绝")
        } catch let error as MessageOrganizationError {
            XCTAssertEqual(error, .tagTooLong(MessageTagRules.maxLength))
        }
        let tags = try await repo.tags(ofMessage: "m1")
        XCTAssertEqual(tags, ["旅行"], "失败不得留下半改状态")
    }

    func testRenameTagIsNoopWhenSourceMissingOrSame() async throws {
        _ = try await repo.addTag("旅行", to: ["m1"], at: 5000)
        let same = try await repo.renameTag("旅行", to: "旅行", at: 6000)
        let missing = try await repo.renameTag("不存在", to: "出游", at: 6000)
        XCTAssertEqual(same, 0)
        XCTAssertEqual(missing, 0)
        let tags = try await repo.tags(ofMessage: "m1")
        XCTAssertEqual(tags, ["旅行"])
    }
}

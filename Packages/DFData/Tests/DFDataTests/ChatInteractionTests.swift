import XCTest
import GRDB
import DFCore
@testable import DFData

/// W2-3 / W2-4 / W2-5 / W2-7：编辑留痕、撤回、收藏、四类删除、会话内搜索、主题设置。
final class ChatInteractionTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFInteract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        try await seed()
    }

    override func tearDownWithError() throws {
        database = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func seed() async throws {
        try await database.write { db in
            for (id, title) in [("c1", "主会话"), ("c2", "另一个会话")] {
                try db.execute(
                    sql: "INSERT INTO conversations (id, title, kind, created_at, updated_at) VALUES (?, ?, 'main', 1, 1)",
                    arguments: [id, title]
                )
            }
            let rows: [(String, String, String, Int64)] = [
                ("m1", "c1", "今天去看了摄影展", 1000),
                ("m2", "c1", "拍到一只橘猫", 2000),
                ("m3", "c1", "100% 喜欢你", 3000),
                ("m4", "c2", "另一个会话里的摄影话题", 4000)
            ]
            for (id, conversation, text, millis) in rows {
                try db.execute(
                    sql: """
                    INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
                    VALUES (?, ?, ?, 'user', 'text', ?, 'sent', 'user', ?)
                    """,
                    arguments: [id, "uuid-\(id)", conversation, text, millis]
                )
            }
        }
        let search = GRDBChatSearchRepository(database: database)
        _ = try? await search.rebuildIndex(conversationID: nil)
    }

    private func messageRow(_ id: String) throws -> Row? {
        try database.dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM messages WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - 编辑

    func testEditWritesHistoryAndUpdatesIndex() async throws {
        let editing = GRDBMessageEditingRepository(database: database)
        let outcome = try await editing.editMessage(id: "m1", newText: "今天去看摄影展了", editedAt: 5000)
        XCTAssertEqual(outcome.version, 1)
        XCTAssertTrue(outcome.changed)

        let row = try XCTUnwrap(try messageRow("m1"))
        XCTAssertEqual(String.fromDatabaseValue(row["text"]), "今天去看摄影展了")
        XCTAssertEqual(Int.fromDatabaseValue(row["edit_count"]), 1)

        let history = try await editing.editHistory(messageID: "m1")
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].beforeText, "今天去看了摄影展")
        XCTAssertEqual(history[0].afterText, "今天去看摄影展了")

        let search = GRDBChatSearchRepository(database: database)
        let hits = try await search.search(query: "摄影展了", conversationID: "c1", limit: 10)
        XCTAssertEqual(hits.map(\.messageID), ["m1"], "编辑后必须按新正文命中")
    }

    func testEditWithoutChangeDoesNotWriteHistory() async throws {
        let editing = GRDBMessageEditingRepository(database: database)
        let outcome = try await editing.editMessage(id: "m1", newText: "今天去看了摄影展", editedAt: 5000)
        XCTAssertFalse(outcome.changed)
        XCTAssertEqual(outcome.version, 0)
        let history = try await editing.editHistory(messageID: "m1")
        XCTAssertTrue(history.isEmpty)
    }

    func testEditRejectsEmptyAndDeleted() async throws {
        let editing = GRDBMessageEditingRepository(database: database)
        do {
            _ = try await editing.editMessage(id: "m1", newText: "   ", editedAt: 5000)
            XCTFail("空正文必须被拒绝")
        } catch let error as MessageInteractionError {
            XCTAssertEqual(error, .emptyText)
        }

        let deletion = GRDBMessageDeletionRepository(database: database)
        _ = try await deletion.softDelete(.ids(["m2"]), in: nil, at: 6000)
        do {
            _ = try await editing.editMessage(id: "m2", newText: "改一下", editedAt: 6000)
            XCTFail("已删除消息不可编辑")
        } catch let error as MessageInteractionError {
            XCTAssertEqual(error, .deleted)
        }
    }

    // MARK: - 撤回

    func testRevokeKeepsOriginalTextAndHidesFromSearch() async throws {
        let editing = GRDBMessageEditingRepository(database: database)
        try await editing.revokeMessage(id: "m1", reason: "说错了", revokedAt: 7000)

        let row = try XCTUnwrap(try messageRow("m1"))
        XCTAssertEqual(String.fromDatabaseValue(row["status"]), "recalled")
        XCTAssertNotNil(Int64.fromDatabaseValue(row["revoked_at"]))
        XCTAssertEqual(String.fromDatabaseValue(row["text"]), "今天去看了摄影展", "撤回不删除原文")
        XCTAssertEqual(String.fromDatabaseValue(row["revoke_reason"]), "说错了")

        let search = GRDBChatSearchRepository(database: database)
        let hits = try await search.search(query: "摄影", conversationID: "c1", limit: 10)
        XCTAssertFalse(hits.contains { $0.messageID == "m1" }, "已撤回消息不得出现在搜索结果")

        do {
            try await editing.revokeMessage(id: "m1", reason: nil, revokedAt: 8000)
            XCTFail("重复撤回必须报错")
        } catch let error as MessageInteractionError {
            XCTAssertEqual(error, .revoked)
        }
    }

    // MARK: - 收藏

    func testFavoriteToggle() async throws {
        let editing = GRDBMessageEditingRepository(database: database)
        try await editing.setFavorite(id: "m2", isFavorite: true, at: 9000)

        var row = try XCTUnwrap(try messageRow("m2"))
        XCTAssertEqual(Int64.fromDatabaseValue(row["is_favorite"]), 1)
        XCTAssertEqual(Int64.fromDatabaseValue(row["favorited_at"]), 9000)

        try await editing.setFavorite(id: "m2", isFavorite: false, at: 9100)
        row = try XCTUnwrap(try messageRow("m2"))
        XCTAssertEqual(Int64.fromDatabaseValue(row["is_favorite"]), 0)
        XCTAssertNil(Int64.fromDatabaseValue(row["favorited_at"]), "取消收藏必须清空收藏时间")
    }

    // MARK: - 四类删除

    func testDeleteByIdsScopedToConversation() async throws {
        let deletion = GRDBMessageDeletionRepository(database: database)
        let count = try await deletion.softDelete(.ids(["m1", "m4"]), in: "c1", at: 10_000)
        XCTAssertEqual(count, 1, "跨会话的 id 必须被忽略")

        XCTAssertNotNil(Int64.fromDatabaseValue(try XCTUnwrap(messageRow("m1"))["deleted_at"]))
        XCTAssertNil(Int64.fromDatabaseValue(try XCTUnwrap(messageRow("m4"))["deleted_at"]))
    }

    func testDeleteByDateRange() async throws {
        let deletion = GRDBMessageDeletionRepository(database: database)
        let count = try await deletion.softDelete(
            .dateRange(fromMillis: 1500, toMillis: 3500),
            in: "c1",
            at: 10_000
        )
        XCTAssertEqual(count, 2)
        XCTAssertNil(Int64.fromDatabaseValue(try XCTUnwrap(messageRow("m1"))["deleted_at"]))
        XCTAssertNotNil(Int64.fromDatabaseValue(try XCTUnwrap(messageRow("m2"))["deleted_at"]))
        XCTAssertNotNil(Int64.fromDatabaseValue(try XCTUnwrap(messageRow("m3"))["deleted_at"]))
    }

    func testDeleteByKeywordUsesLiteralMatch() async throws {
        let deletion = GRDBMessageDeletionRepository(database: database)
        // `%` 必须按字面量匹配，不能当通配符
        let literal = try await deletion.softDelete(.keyword("100%"), in: "c1", at: 10_000)
        XCTAssertEqual(literal, 1)

        let wildcard = try await deletion.softDelete(.keyword("橘"), in: "c1", at: 10_000)
        XCTAssertEqual(wildcard, 1)
    }

    func testClearConversationKeepsOtherConversation() async throws {
        let deletion = GRDBMessageDeletionRepository(database: database)
        let count = try await deletion.softDelete(.conversation("c1"), in: nil, at: 10_000)
        XCTAssertEqual(count, 3)
        XCTAssertNil(Int64.fromDatabaseValue(try XCTUnwrap(messageRow("m4"))["deleted_at"]))
    }

    // MARK: - 搜索

    func testSearchIsScopedAndIgnoresDeleted() async throws {
        let search = GRDBChatSearchRepository(database: database)
        let inConversation = try await search.search(query: "摄影", conversationID: "c1", limit: 10)
        XCTAssertEqual(inConversation.map(\.messageID), ["m1"])

        let global = try await search.search(query: "摄影", conversationID: nil, limit: 10)
        XCTAssertEqual(Set(global.map(\.messageID)), Set(["m1", "m4"]))

        let deletion = GRDBMessageDeletionRepository(database: database)
        _ = try await deletion.softDelete(.ids(["m1"]), in: nil, at: 10_000)
        let afterDelete = try await search.search(query: "摄影", conversationID: nil, limit: 10)
        XCTAssertEqual(afterDelete.map(\.messageID), ["m4"])
    }

    func testRebuildIndexCoversLegacyRows() async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM message_fts")
        }
        let search = GRDBChatSearchRepository(database: database)
        let indexed = try await search.rebuildIndex(conversationID: nil)
        XCTAssertEqual(indexed, 4)
        let hits = try await search.search(query: "橘猫", conversationID: nil, limit: 10)
        XCTAssertEqual(hits.map(\.messageID), ["m2"])
    }

    // MARK: - 主题

    func testThemeDefaultsSaveLoadReset() async throws {
        let store = GRDBChatThemeStore(settings: GRDBSettingsRepository(database: database))
        let initial = try await store.load()
        XCTAssertEqual(initial, .default)

        var theme = ChatTheme.default
        theme.themeID = "night"
        theme.fontScale = 1.2
        try await store.save(theme)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, theme)

        let reset = try await store.reset()
        XCTAssertEqual(reset, .default)
        let afterReset = try await store.load()
        XCTAssertEqual(afterReset, .default)
    }

    func testThemeRejectsCorruptDataAndClampsValues() async throws {
        let settings = GRDBSettingsRepository(database: database)
        try await settings.set("{not json", for: ChatTheme.storageKey)
        let store = GRDBChatThemeStore(settings: settings)
        let corrupt = try await store.load()
        XCTAssertEqual(corrupt, .default, "坏数据必须回落默认")

        let illegal = ChatTheme(
            themeID: "unknown",
            background: "neon",
            bubbleStyle: "glass",
            fontScale: 9,
            avatarStyle: "robot"
        )
        let normalized = illegal.normalized()
        XCTAssertEqual(normalized.themeID, ChatTheme.default.themeID)
        XCTAssertEqual(normalized.background, ChatTheme.default.background)
        XCTAssertEqual(normalized.bubbleStyle, ChatTheme.default.bubbleStyle)
        XCTAssertEqual(normalized.avatarStyle, ChatTheme.default.avatarStyle)
        XCTAssertEqual(normalized.fontScale, ChatTheme.fontScaleRange.upperBound)
    }
}

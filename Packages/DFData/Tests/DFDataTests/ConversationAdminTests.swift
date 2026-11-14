import XCTest
import GRDB
import DFCore
@testable import DFData

/// W3-1 ~ W3-6：多会话管理（建 / 改名 / 置顶 / 归档 / 排序 / 未读 / 删除保留记忆）。
final class ConversationAdminTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var repo: GRDBConversationAdminRepository!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFConvAdmin-\(UUID().uuidString)", isDirectory: true)
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
            let rows: [(String, String, String, Int64)] = [
                ("c1", "主会话", "main", 1000),
                ("c2", "摄影", "chat", 2000),
                ("c3", "工作", "chat", 3000)
            ]
            for (id, title, kind, millis) in rows {
                try db.execute(
                    sql: """
                    INSERT INTO conversations (id, title, kind, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [id, title, kind, millis, millis]
                )
            }
            let messages: [(String, String, String, Int64)] = [
                ("m1", "c1", "今天去看了摄影展", 1000),
                ("m2", "c1", "拍到一只橘猫", 2000),
                ("m3", "c2", "摄影笔记第二篇", 3000)
            ]
            for (id, conversation, text, millis) in messages {
                try db.execute(
                    sql: """
                    INSERT INTO messages
                        (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
                    VALUES (?, ?, ?, 'user', 'text', ?, 'sent', 'user', ?)
                    """,
                    arguments: [id, "uuid-\(id)", conversation, text, millis]
                )
            }
            try db.execute(sql: """
                INSERT INTO memories (id, type, title, content, importance, first_seen_at, scope)
                VALUES ('mem1', 'event', '看过摄影笔记', '用户提到摄影笔记', 'normal', 1000, 'shared')
                """)
            // 记忆来源指向 c2 里的 m3：删除会话后必须仍能读到这条记忆
            try db.execute(sql: """
                INSERT INTO memory_sources (id, memory_id, source_type, source_id, excerpt, at, created_at)
                VALUES ('s1', 'mem1', 'message', 'm3', '摄影笔记第二篇', 3000, 3000)
                """)
        }
        let search = GRDBChatSearchRepository(database: database)
        _ = try? await search.rebuildIndex(conversationID: nil)
    }

    private func count(
        _ table: String,
        where clause: String = "1=1",
        _ args: [any DatabaseValueConvertible] = []
    ) throws -> Int {
        try database.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM \(table) WHERE \(clause)",
                arguments: StatementArguments(args)
            ) ?? 0
        }
    }

    // MARK: - 建 / 改名

    func testCreatePutsNewConversationFirstAndTrimsTitle() async throws {
        let created = try await repo.create(title: "  新话题  ", kind: "chat", at: 5000)
        XCTAssertEqual(created.title, "新话题")
        XCTAssertEqual(created.kind, "chat")
        XCTAssertEqual(created.messageCount, 0)
        XCTAssertNil(created.lastMessageAt)
        XCTAssertFalse(created.isPinned)

        let list = try await repo.list(.active)
        XCTAssertEqual(list.first?.id, created.id, "新建会话应排在未置顶列表最前")
        XCTAssertEqual(list.count, 4)
    }

    func testCreateRejectsEmptyTitle() async throws {
        do {
            _ = try await repo.create(title: "   ", kind: "chat", at: 5000)
            XCTFail("空标题必须拒绝")
        } catch let error as ConversationAdminError {
            XCTAssertEqual(error, .emptyTitle)
        }
    }

    func testRenameDoesNotChangeActivityAndRejectsBadInput() async throws {
        try await repo.rename(id: "c2", title: "  摄影记录  ")
        let renamed = try await repo.summary(id: "c2")
        let summary = try XCTUnwrap(renamed)
        XCTAssertEqual(summary.title, "摄影记录")
        XCTAssertEqual(summary.updatedAt, 2000, "改名不是最近活动，不得改动 updated_at")

        do {
            try await repo.rename(id: "c2", title: "")
            XCTFail("空标题必须拒绝")
        } catch let error as ConversationAdminError {
            XCTAssertEqual(error, .emptyTitle)
        }
        do {
            try await repo.rename(id: "missing", title: "x")
            XCTFail("不存在的会话必须报错")
        } catch let error as ConversationAdminError {
            XCTAssertEqual(error, .notFound)
        }
    }

    // MARK: - 置顶 / 归档

    func testPinAndUnpinChangeListOrder() async throws {
        try await repo.setPinned(id: "c3", pinned: true, at: 9000)
        var list = try await repo.list(.active)
        XCTAssertEqual(list.first?.id, "c3")
        XCTAssertTrue(list.first?.isPinned == true)

        try await repo.setPinned(id: "c3", pinned: false, at: 9500)
        list = try await repo.list(.active)
        XCTAssertEqual(list.map(\.id), ["c3", "c2", "c1"], "取消置顶后按最近活动倒序")
    }

    func testArchivedConversationLeavesActiveListButMessagesStaySearchable() async throws {
        try await repo.setArchived(id: "c2", archived: true, at: 9000)

        let active = try await repo.list(.active)
        XCTAssertFalse(active.contains { $0.id == "c2" })
        let archived = try await repo.list(.archived)
        XCTAssertEqual(archived.map(\.id), ["c2"])
        XCTAssertTrue(archived[0].isArchived)
        XCTAssertEqual(archived[0].messageCount, 1)

        let search = GRDBChatSearchRepository(database: database)
        let hits = try await search.search(query: "摄影笔记", conversationID: nil, limit: 10)
        XCTAssertEqual(hits.map(\.messageID), ["m3"], "归档会话的消息仍必须可检索")
    }

    func testArchivingMainConversationIsRejected() async throws {
        do {
            try await repo.setArchived(id: "c1", archived: true, at: 9000)
            XCTFail("主会话不可归档")
        } catch let error as ConversationAdminError {
            XCTAssertEqual(error, .mainConversationProtected)
        }
    }

    // MARK: - 未读

    func testUnreadIncrementClampsAndMarkRead() async throws {
        try await repo.incrementUnread(id: "c2", by: 3, at: 4000)
        let first = try await repo.summary(id: "c2")
        var summary = try XCTUnwrap(first)
        XCTAssertEqual(summary.unreadCount, 3)
        XCTAssertEqual(summary.updatedAt, 4000)

        try await repo.incrementUnread(id: "c2", by: -5, at: 4500)
        let clamped = try await repo.summary(id: "c2")
        summary = try XCTUnwrap(clamped)
        XCTAssertEqual(summary.unreadCount, 0, "未读数不得为负")

        try await repo.incrementUnread(id: "c2", by: 2, at: 4600)
        let totalBefore = try await repo.unreadTotal()
        XCTAssertEqual(totalBefore, 2)

        try await repo.markRead(id: "c2", at: 5000)
        let read = try await repo.summary(id: "c2")
        summary = try XCTUnwrap(read)
        XCTAssertEqual(summary.unreadCount, 0)
        XCTAssertEqual(summary.lastReadAt, 5000)
        let totalAfter = try await repo.unreadTotal()
        XCTAssertEqual(totalAfter, 0)
    }

    func testMarkAllReadCoversAllConversations() async throws {
        try await repo.incrementUnread(id: "c1", by: 1, at: 4000)
        try await repo.incrementUnread(id: "c2", by: 4, at: 4100)
        let affected = try await repo.markAllRead(at: 5000)
        XCTAssertEqual(affected, 2)
        let total = try await repo.unreadTotal()
        XCTAssertEqual(total, 0)

        let list = try await repo.list(.all)
        XCTAssertTrue(list.allSatisfy { $0.unreadCount == 0 && $0.lastReadAt == 5000 })
    }

    // MARK: - 排序

    func testReorderAppliesGivenOrderAndKeepsRemainder() async throws {
        try await repo.reorder(ids: ["c1", "c2", "c3"])
        var list = try await repo.list(.active)
        XCTAssertEqual(list.map(\.id), ["c1", "c2", "c3"])

        try await repo.reorder(ids: ["c3"])
        list = try await repo.list(.active)
        XCTAssertEqual(list.map(\.id), ["c3", "c1", "c2"], "未列出的会话保持原有相对顺序")

        try await repo.reorder(ids: ["missing", "c2"])
        list = try await repo.list(.active)
        XCTAssertEqual(list.first?.id, "c2", "未知 id 必须被忽略而不是报错")
    }

    // MARK: - 删除

    func testDeleteRemovesMessagesAndIndexButKeepsMemories() async throws {
        let result = try await repo.delete(id: "c2")
        XCTAssertEqual(result.deletedConversations, 1)
        XCTAssertEqual(result.deletedMessages, 1)
        XCTAssertEqual(result.skippedProtected, 0)

        let removed = try await repo.summary(id: "c2")
        XCTAssertNil(removed)
        let remainingMessages = try count("messages", where: "conversation_id = ?", ["c2"])
        XCTAssertEqual(remainingMessages, 0)
        let remainingIndex = try count("message_fts", where: "conversation_id = ?", ["c2"])
        XCTAssertEqual(remainingIndex, 0)
        let keptMemories = try count("memories", where: "id = ?", ["mem1"])
        XCTAssertEqual(keptMemories, 1, "删除会话不得删除记忆")
        let keptSources = try count("memory_sources", where: "source_id = ?", ["m3"])
        XCTAssertEqual(keptSources, 1, "来源记录保留")

        let search = GRDBChatSearchRepository(database: database)
        let hits = try await search.search(query: "摄影笔记", conversationID: nil, limit: 10)
        XCTAssertTrue(hits.isEmpty, "已删除会话的消息不得再被搜索命中")
    }

    func testDeleteMainConversationIsSkipped() async throws {
        let result = try await repo.delete(id: "c1")
        XCTAssertEqual(result.deletedConversations, 0)
        XCTAssertEqual(result.deletedMessages, 0)
        XCTAssertEqual(result.skippedProtected, 1)
        let kept = try await repo.summary(id: "c1")
        XCTAssertNotNil(kept)
        let messageCount = try count("messages", where: "conversation_id = ?", ["c1"])
        XCTAssertEqual(messageCount, 2)
    }

    func testDeleteBatchIsIdempotentForMissingIds() async throws {
        let result = try await repo.deleteBatch(ids: ["c2", "c3", "missing", "c2"])
        XCTAssertEqual(result.deletedConversations, 2)
        XCTAssertEqual(result.deletedMessages, 1)
        let remaining = try count("conversations")
        XCTAssertEqual(remaining, 1)
    }

    // MARK: - 计数

    func testSummaryCountsOnlyVisibleMessages() async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE messages SET deleted_at = 1500 WHERE id = 'm2'"
            )
        }
        let current = try await repo.summary(id: "c1")
        let summary = try XCTUnwrap(current)
        XCTAssertEqual(summary.messageCount, 1)
        XCTAssertEqual(summary.lastMessageAt, 1000, "软删消息不参与最近活动时间")
    }
}

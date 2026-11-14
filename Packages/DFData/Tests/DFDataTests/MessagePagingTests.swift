import XCTest
import GRDB
import DFCore
@testable import DFData

/// 分页与上下文单元测试（PG01–PG09），全部基于真实 SQLite。
final class MessagePagingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFPage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - 辅助

    private func makeDatabase(_ name: String) throws -> AppDatabase {
        let database = try AppDatabase(paths: DatabasePaths(root: root.appendingPathComponent(name, isDirectory: true)))
        return database
    }

    private func seedConversation(_ database: AppDatabase) async throws {
        try await database.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '大肥鱼', 'main', 1, 1)
            """)
        }
    }

    /// 批量插入消息，返回 id 列表（按插入顺序，即 rowid 顺序）
    @discardableResult
    private func insertMessages(
        _ database: AppDatabase,
        count: Int,
        createdAt: Int64,
        prefix: String,
        groupID: String? = nil,
        seqStart: Int? = nil,
        deleted: Bool = false
    ) async throws -> [String] {
        var ids: [String] = []
        for index in 0..<count {
            let id = "\(prefix)-\(index)"
            ids.append(id)
            try await database.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin,
                                          created_at, deleted_at, group_id, seq_in_group)
                    VALUES (?, ?, 'c1', 'user', 'text', ?, 'sent', 'user', ?, ?, ?, ?)
                    """,
                    arguments: [
                        id,
                        "uuid-\(id)",
                        "\(prefix) 第\(index)条",
                        createdAt,
                        deleted ? createdAt + 1 : nil,
                        groupID,
                        seqStart.map { $0 + index }
                    ]
                )
            }
        }
        return ids
    }

    /// 翻完所有页，返回按时间升序拼接的消息 id 序列（新页前插）
    private func pageThrough(
        _ repository: GRDBMessageRepository,
        limit: Int,
        maxPages: Int = 100
    ) async throws -> (ids: [String], pages: Int) {
        var ids: [String] = []
        var cursor: PageCursor?
        var pages = 0
        while pages < maxPages {
            let page = try await repository.page(in: "c1", before: cursor, limit: limit)
            pages += 1
            ids.insert(contentsOf: page.items.map(\.id), at: 0)
            guard page.hasMore, let next = page.nextCursor else { break }
            cursor = next
        }
        return (ids, pages)
    }

    // MARK: - PG01 同一毫秒稳定分页

    func testPG01_SameCreatedAtStablePaging() async throws {
        let database = try makeDatabase("pg01")
        try await seedConversation(database)
        let inserted = try await insertMessages(database, count: 6, createdAt: 5000, prefix: "same")
        let repository = GRDBMessageRepository(database: database)

        let first = try await repository.page(in: "c1", before: nil, limit: 2)
        XCTAssertEqual(first.items.map(\.id), ["same-4", "same-5"], "同毫秒下必须按 rowid 由新到旧返回升序")
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.nextCursor?.createdAt, 5000)
        XCTAssertNotNil(first.nextCursor?.rowid)

        let result = try await pageThrough(repository, limit: 2)
        XCTAssertEqual(result.ids.count, 6, "不得重复、不得遗漏")
        XCTAssertEqual(Set(result.ids), Set(inserted))

        // 跨页拼接后整体顺序 = rowid 升序（即插入顺序）
        XCTAssertEqual(result.ids, inserted)

        // recentMessages 的双键排序同样生效
        let recent = try await repository.recentMessages(in: "c1", limit: 3)
        XCTAssertEqual(recent.map(\.id), ["same-3", "same-4", "same-5"])
    }

    // MARK: - PG02 末页与空页

    func testPG02_ReachEndAndEmptyPage() async throws {
        let database = try makeDatabase("pg02")
        try await seedConversation(database)
        try await insertMessages(database, count: 3, createdAt: 1000, prefix: "end")
        let repository = GRDBMessageRepository(database: database)

        let page = try await repository.page(in: "c1", before: nil, limit: 10)
        XCTAssertEqual(page.items.count, 3)
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.nextCursor, "没有更早消息时不返回游标")

        let oldest = try await database.dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT rowid FROM messages ORDER BY created_at ASC, rowid ASC LIMIT 1")
        }
        let empty = try await repository.page(
            in: "c1",
            before: PageCursor(createdAt: 1000, rowid: oldest ?? 1),
            limit: 10
        )
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertFalse(empty.hasMore)
        XCTAssertNil(empty.nextCursor)
    }

    // MARK: - PG03 软删不出现、不占条数

    func testPG03_SoftDeletedExcluded() async throws {
        let database = try makeDatabase("pg03")
        try await seedConversation(database)
        try await insertMessages(database, count: 4, createdAt: 1000, prefix: "live")
        try await insertMessages(database, count: 2, createdAt: 2000, prefix: "gone", deleted: true)
        let repository = GRDBMessageRepository(database: database)

        let page = try await repository.page(in: "c1", before: nil, limit: 10)
        XCTAssertEqual(page.items.count, 4, "软删消息不得占用条数")
        XCTAssertTrue(page.items.allSatisfy { !$0.id.hasPrefix("gone") })

        let total = try await repository.count(in: "c1")
        XCTAssertEqual(total, 4)
    }

    // MARK: - PG04 300+ 消息分页

    func testPG04_ThreeHundredPlusMessages() async throws {
        let database = try makeDatabase("pg04")
        try await seedConversation(database)
        // 一次事务批量写入，避免 320 次独立提交
        try await database.write { db in
            for index in 0..<320 {
                try db.execute(
                    sql: """
                    INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
                    VALUES (?, ?, 'c1', 'user', 'text', ?, 'sent', 'user', ?)
                    """,
                    arguments: ["bulk-\(index)", "uuid-bulk-\(index)", "第\(index)条", Int64(1000 + index)]
                )
            }
        }
        let repository = GRDBMessageRepository(database: database)

        let first = try await repository.page(in: "c1", before: nil, limit: 100)
        XCTAssertEqual(first.items.count, 100)
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.items.first?.id, "bulk-220", "首屏应是最近 100 条（升序返回，最旧在前）")
        XCTAssertEqual(first.items.last?.id, "bulk-319")

        let result = try await pageThrough(repository, limit: 100, maxPages: 10)
        XCTAssertEqual(result.ids.count, 320)
        XCTAssertEqual(Set(result.ids).count, 320, "翻完所有页不得重复")
        XCTAssertEqual(result.ids.first, "bulk-0")
        XCTAssertEqual(result.ids.last, "bulk-319")
    }

    // MARK: - PG05 recentUnits 与 UI 条数无关

    func testPG05_ContextIndependentOfUILimit() async throws {
        let database = try makeDatabase("pg05")
        try await seedConversation(database)
        let groups = GRDBMessageGroupRepository(database: database)

        // 23 条 legacy 无组消息
        let legacyIDs = try await insertMessages(database, count: 23, createdAt: 100, prefix: "legacy")

        // 25 个真实组
        for index in 0..<25 {
            _ = try await groups.openTurn(
                OpenTurnRequest(
                    group: MessageGroup(conversationID: "c1", turnIndex: 0, openedAt: Int64(1000 + index)),
                    userMessage: Message(
                        conversationID: "c1", role: .user, text: "问\(index)",
                        status: .sent, origin: .user, createdAt: Int64(1000 + index)
                    ),
                    assistantMessage: Message(
                        conversationID: "c1", role: .assistant, text: "答\(index)",
                        status: .sending, origin: .reply, createdAt: Int64(1000 + index) + 1
                    )
                )
            )
        }

        let provider = GRDBContextUnitProvider(database: database)
        let units = try await provider.recentUnits(conversationID: "c1", limitGroups: 20)

        let virtualUnits = units.filter { $0.group == nil }
        let groupUnits = units.filter { $0.group != nil }
        XCTAssertEqual(groupUnits.count, 20, "limitGroups 只限制真实组")
        XCTAssertEqual(virtualUnits.count, 23, "legacy 消息不得被 limitGroups 丢弃")
        XCTAssertEqual(virtualUnits.flatMap { $0.messages.map(\.id) }, legacyIDs)

        // 归并后整体按时间升序
        let timestamps = units.compactMap { $0.messages.first?.createdAt }
        XCTAssertEqual(timestamps, timestamps.sorted())

        // 最近 20 组的轮次必须是 6...25
        let turnIndices = groupUnits.compactMap { $0.group?.turnIndex }
        XCTAssertEqual(turnIndices, Array(6...25))

        // UI 首屏只取 100 条不影响上下文取组：上下文里仍是 20 组 + 23 条
        let firstScreen = try await GRDBMessageRepository(database: database).page(in: "c1", before: nil, limit: 100)
        XCTAssertEqual(firstScreen.items.count, 73, "23 条 legacy + 25 组 × 2 条")
        XCTAssertEqual(units.count, 43)
    }

    // MARK: - PG06 同毫秒 5 条分 2 页

    func testPG06_FiveSameTimestampTwoPages() async throws {
        let database = try makeDatabase("pg06")
        try await seedConversation(database)
        let inserted = try await insertMessages(database, count: 5, createdAt: 7777, prefix: "tie")
        let repository = GRDBMessageRepository(database: database)

        let page1 = try await repository.page(in: "c1", before: nil, limit: 3)
        XCTAssertEqual(page1.items.map(\.id), ["tie-2", "tie-3", "tie-4"])
        XCTAssertTrue(page1.hasMore)

        let page2 = try await repository.page(in: "c1", before: page1.nextCursor, limit: 3)
        XCTAssertEqual(page2.items.map(\.id), ["tie-0", "tie-1"])
        XCTAssertFalse(page2.hasMore)
        XCTAssertNil(page2.nextCursor)

        let combined = page2.items.map(\.id) + page1.items.map(\.id)
        XCTAssertEqual(combined, inserted, "同毫秒两页拼接必须无重复、无遗漏且顺序确定")
    }

    // MARK: - PG07 翻页过程中新增消息

    func testPG07_NewMessageDuringPaging() async throws {
        let database = try makeDatabase("pg07")
        try await seedConversation(database)
        try await insertMessages(database, count: 6, createdAt: 1000, prefix: "old")
        let repository = GRDBMessageRepository(database: database)

        let page1 = try await repository.page(in: "c1", before: nil, limit: 3)
        XCTAssertEqual(page1.items.map(\.id), ["old-3", "old-4", "old-5"])

        // 翻页途中插入新消息（时间更新）
        try await insertMessages(database, count: 1, createdAt: 9000, prefix: "new")

        let page2 = try await repository.page(in: "c1", before: page1.nextCursor, limit: 3)
        XCTAssertEqual(page2.items.map(\.id), ["old-0", "old-1", "old-2"], "新消息不得插入已开始的翻页序列")
        XCTAssertFalse(page2.hasMore)
    }

    // MARK: - PG08 翻页过程中软删

    func testPG08_SoftDeleteDuringPaging() async throws {
        let database = try makeDatabase("pg08")
        try await seedConversation(database)
        try await insertMessages(database, count: 6, createdAt: 1000, prefix: "del")
        let repository = GRDBMessageRepository(database: database)

        let page1 = try await repository.page(in: "c1", before: nil, limit: 3)
        XCTAssertEqual(page1.items.map(\.id), ["del-3", "del-4", "del-5"])

        // 删除一条尚未翻到的旧消息
        try await database.write { db in
            try db.execute(sql: "UPDATE messages SET deleted_at = 9999 WHERE id = 'del-1'")
        }

        let page2 = try await repository.page(in: "c1", before: page1.nextCursor, limit: 3)
        XCTAssertEqual(page2.items.map(\.id), ["del-0", "del-2"], "软删后无空洞、无重复")
        XCTAssertFalse(page2.hasMore)
    }

    // MARK: - PG09 limit 夹取

    func testPG09_LimitClamped() async throws {
        let database = try makeDatabase("pg09")
        try await seedConversation(database)
        try await database.write { db in
            for index in 0..<250 {
                try db.execute(
                    sql: """
                    INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
                    VALUES (?, ?, 'c1', 'user', 'text', ?, 'sent', 'user', ?)
                    """,
                    arguments: ["clamp-\(index)", "uuid-clamp-\(index)", "第\(index)条", Int64(1000 + index)]
                )
            }
        }
        let repository = GRDBMessageRepository(database: database)

        let tiny = try await repository.page(in: "c1", before: nil, limit: 0)
        XCTAssertEqual(tiny.items.count, 1, "limit = 0 夹到 1")

        let huge = try await repository.page(in: "c1", before: nil, limit: 1000)
        XCTAssertEqual(huge.items.count, 200, "limit 上限为 200")
        XCTAssertTrue(huge.hasMore)
    }
}

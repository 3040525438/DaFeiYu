import XCTest
import GRDB
import DFCore
@testable import DFData

/// W2-1 多气泡落库：同一事务写入多条气泡、序号连续、空段忽略、索引同步。
final class MultiBubbleTurnTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFBubble-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeDatabase(_ name: String) throws -> AppDatabase {
        try AppDatabase(paths: DatabasePaths(root: root.appendingPathComponent(name, isDirectory: true)))
    }

    private func openTurn(_ database: AppDatabase) async throws -> MessageGroup {
        try await database.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '大肥鱼', 'main', 1, 1)
            """)
        }
        let groups = GRDBMessageGroupRepository(database: database)
        return try await groups.openTurn(
            OpenTurnRequest(
                group: MessageGroup(conversationID: "c1", turnIndex: 0, openedAt: 1000),
                userMessage: Message(
                    conversationID: "c1", role: .user, text: "在吗",
                    status: .sent, origin: .user, createdAt: 1000
                ),
                assistantMessage: Message(
                    conversationID: "c1", role: .assistant, text: "",
                    status: .sending, origin: .reply, createdAt: 1001
                )
            )
        )
    }

    private func finalize(
        _ database: AppDatabase,
        group: MessageGroup,
        bubbles: [String]
    ) async throws {
        let turns = GRDBMessageTurnRepository(database: database)
        try await turns.finalizeTurn(
            FinalizeTurnRequest(
                groupID: group.id,
                assistantMessageID: group.assistantMessageID!,
                text: bubbles.first ?? "",
                assistantStatus: .sent,
                sentAt: 2000,
                replyToID: nil,
                references: [],
                groupStatus: .complete,
                closedAt: 2000,
                additionalBubbles: Array(bubbles.dropFirst())
            )
        )
    }

    private func assistantRows(_ database: AppDatabase, groupID: String) async throws -> [Message] {
        let repo = GRDBMessageRepository(database: database)
        return try await repo.messages(inGroup: groupID).filter { $0.role == .assistant }
    }

    // MARK: - 多气泡落库

    func testAdditionalBubblesAreStoredAsIndependentMessages() async throws {
        let database = try makeDatabase("multi")
        let group = try await openTurn(database)
        try await finalize(database, group: group, bubbles: ["第一句", "第二句", "第三句"])

        let rows = try await assistantRows(database, groupID: group.id)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.text), ["第一句", "第二句", "第三句"])
        XCTAssertEqual(rows.map(\.seqInGroup), [1, 2, 3], "序号必须连续且从首条之后递增")
        XCTAssertEqual(Set(rows.map(\.id)).count, 3, "每条气泡必须有自己的 messageID")
        XCTAssertTrue(rows.allSatisfy { $0.status == .sent })
        XCTAssertEqual(rows.first?.id, group.assistantMessageID, "首条气泡沿用事务 A 的 assistant 行")
    }

    func testEmptyBubblesAreIgnored() async throws {
        let database = try makeDatabase("empty")
        let group = try await openTurn(database)
        try await finalize(database, group: group, bubbles: ["只有这句", "", "   "])

        let rows = try await assistantRows(database, groupID: group.id)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.text, "只有这句")
    }

    func testGroupStillCompleteAfterMultiBubble() async throws {
        let database = try makeDatabase("status")
        let group = try await openTurn(database)
        try await finalize(database, group: group, bubbles: ["A", "B"])

        let groups = GRDBMessageGroupRepository(database: database)
        let reloaded = try await groups.group(id: group.id)
        XCTAssertEqual(reloaded?.status, .complete)
        XCTAssertNotNil(reloaded?.closedAt)
    }

    // MARK: - 全文索引同步

    func testBubblesAreIndexedForSearch() async throws {
        let database = try makeDatabase("fts")
        let group = try await openTurn(database)
        try await finalize(database, group: group, bubbles: ["今天去看了摄影展", "拍到一只猫"])

        let hits: [String] = try await database.dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT message_id FROM message_fts WHERE message_fts MATCH ?",
                arguments: [V2Memory.bigram("摄影")]
            )
        }
        XCTAssertEqual(hits, [group.assistantMessageID!], "含关键词的气泡必须可被检索命中")
    }

    // MARK: - 失败回滚

    func testRollbackLeavesNoPartialBubblesWhenFinalizeFails() async throws {
        let database = try makeDatabase("rollback")
        let group = try await openTurn(database)
        let turns = GRDBMessageTurnRepository(database: database)
        // assistant 已不是 sending（先人为置 sent），定稿必须整体失败
        try await database.write { db in
            try db.execute(
                sql: "UPDATE messages SET status = 'sent' WHERE id = ?",
                arguments: [group.assistantMessageID]
            )
        }

        do {
            try await turns.finalizeTurn(
                FinalizeTurnRequest(
                    groupID: group.id,
                    assistantMessageID: group.assistantMessageID!,
                    text: "首条",
                    assistantStatus: .sent,
                    sentAt: 2000,
                    replyToID: nil,
                    references: [],
                    groupStatus: .complete,
                    closedAt: 2000,
                    additionalBubbles: ["第二条", "第三条"]
                )
            )
            XCTFail("定稿应当失败")
        } catch {
            // 预期路径
        }

        let rows = try await assistantRows(database, groupID: group.id)
        XCTAssertEqual(rows.count, 1, "事务失败不得留下任何部分气泡")
    }
}

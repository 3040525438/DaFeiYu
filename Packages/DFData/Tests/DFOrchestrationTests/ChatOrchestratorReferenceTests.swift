import XCTest
import Foundation
import GRDB
import DFCore
@testable import DFData
import DFOrchestration
/// B1-S3 引用协议测试（B1-04~07）。
/// 真实 SQLite + 真实仓储，验证"尾注不泄漏、引用原子落库、跨会话被丢弃"。
final class ChatOrchestratorReferenceTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var groups: GRDBMessageGroupRepository!
    private var turns: GRDBMessageTurnRepository!
    private var messages: GRDBMessageRepository!
    private var references: GRDBMessageReferenceRepository!
    private var units: GRDBContextUnitProvider!
    private var conversationID: String!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrchRef-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        groups = GRDBMessageGroupRepository(database: database)
        turns = GRDBMessageTurnRepository(database: database)
        messages = GRDBMessageRepository(database: database)
        references = GRDBMessageReferenceRepository(database: database)
        units = GRDBContextUnitProvider(database: database)
        let conversation = try await GRDBConversationRepository(database: database)
            .ensureMainConversation(title: "大肥鱼")
        conversationID = conversation.id
    }

    override func tearDown() async throws {
        database = nil
        groups = nil
        turns = nil
        messages = nil
        references = nil
        units = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    // MARK: - 工具

    private func makeOrchestrator(_ text: String) -> ChatOrchestratorImpl {
        let deps = ChatOrchestratorDependencies(
            groups: groups,
            turns: turns,
            messages: messages,
            references: references,
            units: units,
            makeProvider: { ScriptedProvider(deltas: [.text(text)]) },
            makeRequest: { system, history in
                ChatRequest(model: "fake-model", systemPrompt: system, messages: history)
            }
        )
        return ChatOrchestratorImpl(dependencies: deps)
    }

    @discardableResult
    private func send(_ text: String) async -> (events: [OrchestratorEvent], error: Error?) {
        var events: [OrchestratorEvent] = []
        do {
            for try await event in makeOrchestrator(text).send(text: "提问", conversationID: conversationID) {
                events.append(event)
            }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    private func lastGroup() async throws -> MessageGroup {
        let fetched = try await database.dbQueue.read { db in
            try MessageGroup.order(Column("turn_index").desc).fetchOne(db)
        }
        return try XCTUnwrap(fetched, "数据库中没有消息组：openTurn 未提交或未被执行")
    }

    // MARK: - B1-04 无尾注：可见文本与原始输出逐字符一致

    func testB1_04_PlainTextPassesThroughUnchanged() async throws {
        let raw = "今天去看展了，人不多。\n你呢？"
        let result = await send(raw)
        XCTAssertNil(result.error)

        let group = try await lastGroup()
        XCTAssertEqual(group.status, .complete)
        let rows = try await messages.messages(inGroup: group.id)
        XCTAssertEqual(rows[1].text, raw, "无尾注时必须逐字符一致")
        XCTAssertTrue(result.events.contains(.assistantReplaced(raw)))
        let refs = try await references.references(for: [rows[1].id])
        XCTAssertEqual(refs.count, 0)
    }

    // MARK: - B1-05 尾注在末帧：整段替换，不残留标记

    func testB1_05_TrailingTagIsStrippedFromVisibleText() async throws {
        // 先造一轮历史，让引用 id 进入白名单
        await send("第一条回复")
        let firstGroup = try await lastGroup()
        let firstRows = try await messages.messages(inGroup: firstGroup.id)
        let citableID = firstRows[0].id

        let raw = "我记得你说过。\n<<refs:[\"\(citableID)\"]>>"
        let result = await send(raw)
        XCTAssertNil(result.error)

        let group = try await lastGroup()
        let rows = try await messages.messages(inGroup: group.id)
        XCTAssertFalse(rows[1].text.contains("<<refs"), "正文不得残留尾注")
        XCTAssertEqual(
            rows[1].text.trimmingCharacters(in: .whitespacesAndNewlines),
            "我记得你说过。"
        )

        guard let last = result.events.last, case let .turnCompleted(_, _, citations) = last else {
            return XCTFail("末事件应为 turnCompleted")
        }
        XCTAssertEqual(citations, [citableID])
    }

    // MARK: - B1-06 合法引用在事务 B 中原子落库

    func testB1_06_ValidReferencePersistedInsideTransactionB() async throws {
        await send("第一条回复")
        let firstGroup = try await lastGroup()
        let firstRows = try await messages.messages(inGroup: firstGroup.id)
        let citableID = firstRows[0].id

        let result = await send("回答正文\n<<refs:[\"\(citableID)\"]>>")
        XCTAssertNil(result.error)

        let group = try await lastGroup()
        XCTAssertEqual(group.status, .complete)
        let rows = try await messages.messages(inGroup: group.id)
        let refs = try await references.references(for: [rows[1].id])

        XCTAssertEqual(refs.count, 1, "必须恰好一条引用（事务 B 内写入，未重复 insertBatch）")
        XCTAssertEqual(refs[0].refMessageID, citableID)
        XCTAssertEqual(refs[0].relation, .reply)
        XCTAssertEqual(rows[1].replyToID, citableID, "唯一主引用需回填 reply_to_id")
    }

    // MARK: - B1-07 跨会话 id 被丢弃，正文与组状态不受影响

    func testB1_07_CrossConversationReferenceDropped() async throws {
        // 另一个会话里的一条消息
        let otherConversationID = "other-\(UUID().uuidString)"
        try await database.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO conversations (id, title, kind, created_at, updated_at)
                VALUES (?, '另一个会话', 'main', 1, 1)
                """,
                arguments: [otherConversationID]
            )
            try db.execute(
                sql: """
                INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
                VALUES ('foreign-1', 'foreign-uuid-1', ?, 'user', 'text', '别人的话', 'sent', 'user', 10)
                """,
                arguments: [otherConversationID]
            )
        }

        let result = await send("正文\n<<refs:[\"foreign-1\"]>>")
        XCTAssertNil(result.error)

        let group = try await lastGroup()
        XCTAssertEqual(group.status, .complete, "跨会话引用只丢弃引用，不影响正文与组状态")
        let rows = try await messages.messages(inGroup: group.id)
        XCTAssertEqual(
            rows[1].text.trimmingCharacters(in: .whitespacesAndNewlines),
            "正文"
        )
        let refs = try await references.references(for: [rows[1].id])
        XCTAssertEqual(refs.count, 0)
        XCTAssertNil(rows[1].replyToID)
    }
}

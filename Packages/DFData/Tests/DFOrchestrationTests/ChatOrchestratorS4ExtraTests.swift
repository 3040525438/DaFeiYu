import XCTest
import Foundation
import GRDB
import DFCore
@testable import DFData
import DFOrchestration

/// B1-S4-B / S4-C / S4-D 测试：组级残留兜底、分页边界、重试与并发补测。
/// 全部真实 SQLite；竞争用 Latch 同步，不使用 sleep。
final class ChatOrchestratorS4ExtraTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var groups: GRDBMessageGroupRepository!
    private var turns: GRDBMessageTurnRepository!
    private var messages: GRDBMessageRepository!
    private var references: GRDBMessageReferenceRepository!
    private var units: GRDBContextUnitProvider!
    private var conversationID: String!
    private let pageToken = UUID()

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrchS4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        groups = GRDBMessageGroupRepository(database: database)
        turns = GRDBMessageTurnRepository(database: database)
        messages = GRDBMessageRepository(database: database)
        references = GRDBMessageReferenceRepository(database: database)
        units = GRDBContextUnitProvider(database: database)
        conversationID = try await GRDBConversationRepository(database: database)
            .ensureMainConversation(title: "大肥鱼").id
    }

    override func tearDown() async throws {
        database = nil; groups = nil; turns = nil; messages = nil
        references = nil; units = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    // MARK: - 工具

    private func makeOrchestrator(provider: any ChatModelProvider) -> ChatOrchestratorImpl {
        let deps = ChatOrchestratorDependencies(
            groups: groups,
            turns: turns,
            messages: messages,
            references: references,
            units: units,
            recovery: groups,
            makeProvider: { provider },
            makeRequest: { system, history in
                ChatRequest(model: "fake-model", systemPrompt: system, messages: history)
            }
        )
        return ChatOrchestratorImpl(dependencies: deps, pageToken: pageToken)
    }

    /// 直接构造一个 open 组 + 指定状态的消息（模拟"写了一半被杀"的各种现场）
    @discardableResult
    private func seedGroup(
        userStatus: MessageStatus,
        assistantStatus: MessageStatus?,
        turnIndex: Int = 1
    ) async throws -> String {
        let now = Clock.nowMillis()
        let groupID = UUID().uuidString
        let userMessage = Message(
            id: UUID().uuidString, conversationID: conversationID, role: .user, text: "你好",
            status: userStatus, origin: .user, createdAt: now,
            sentAt: userStatus == .sent ? now : nil
        )
        let assistantMessage = assistantStatus.map {
            Message(
                id: UUID().uuidString, conversationID: conversationID, role: .assistant, text: "半截",
                status: $0, origin: .reply, createdAt: now + 1,
                sentAt: $0 == .sent ? now + 1 : nil
            )
        }
        let group = MessageGroup(
            id: groupID, conversationID: conversationID, turnIndex: turnIndex,
            status: .open, openedAt: now
        )
        let opened = try await groups.openTurn(
            OpenTurnRequest(group: group, userMessage: userMessage, assistantMessage: assistantMessage)
        )
        return opened.id
    }

    private func write(_ sql: String, _ arguments: StatementArguments = []) async throws {
        try await database.dbQueue.write { db in
            try db.execute(sql: sql, arguments: arguments)
        }
    }

    private func groupStatus(_ id: String) async throws -> String? {
        try await database.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM message_groups WHERE id = ?", arguments: [id])
        }
    }

    private func scalarInt(_ sql: String, _ arguments: StatementArguments = []) async throws -> Int {
        try await database.dbQueue.read { db in
            try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
        }
    }

    private func scalarString(_ sql: String, _ arguments: StatementArguments = []) async throws -> String? {
        try await database.dbQueue.read { db in
            try String.fetchOne(db, sql: sql, arguments: arguments)
        }
    }

    private static func collect(
        _ stream: AsyncThrowingStream<OrchestratorEvent, Error>
    ) async -> (events: [OrchestratorEvent], error: Error?) {
        var events: [OrchestratorEvent] = []
        do {
            for try await event in stream { events.append(event) }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    private static func hasTerminal(_ events: [OrchestratorEvent]) -> Bool {
        events.contains {
            switch $0 {
            case .turnCompleted, .turnFailed, .turnCancelled, .turnRecoveryPending: return true
            default: return false
            }
        }
    }

    // MARK: - S4-B-1 组 open + assistant canceled → aborted

    func testS4B_1_OpenGroupWithCanceledAssistantBecomesAborted() async throws {
        let groupID = try await seedGroup(userStatus: .sent, assistantStatus: .canceled)

        let report = try await makeOrchestrator(provider: StaticTextProvider())
            .recoverStaleTurns(conversationID: conversationID)

        XCTAssertEqual(report.closedGroups, 1)
        let status = try await groupStatus(groupID)
        XCTAssertEqual(status, "aborted")
        let closedAt = try await database.dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT closed_at FROM message_groups WHERE id = ?", arguments: [groupID])
        }
        XCTAssertNotNil(closedAt, "必须补 closed_at")
    }

    // MARK: - S4-B-2 组 open + assistant sent → complete

    func testS4B_2_OpenGroupWithSentAssistantBecomesComplete() async throws {
        let groupID = try await seedGroup(userStatus: .sent, assistantStatus: .sent)

        _ = try await makeOrchestrator(provider: StaticTextProvider())
            .recoverStaleTurns(conversationID: conversationID)

        let status = try await groupStatus(groupID)
        XCTAssertEqual(status, "complete")
    }

    // MARK: - S4-B-3 组 open + 无 assistant + user sending → 全 failed

    func testS4B_3_OpenGroupWithoutAssistantBecomesFailed() async throws {
        let groupID = try await seedGroup(userStatus: .sending, assistantStatus: nil)

        let report = try await makeOrchestrator(provider: StaticTextProvider())
            .recoverStaleTurns(conversationID: conversationID)

        XCTAssertEqual(report.closedGroups, 1)
        let status = try await groupStatus(groupID)
        XCTAssertEqual(status, "failed")

        let userStatus = try await scalarString(
            "SELECT status FROM messages WHERE group_id = ? AND role = 'user'", [groupID]
        )
        XCTAssertEqual(userStatus, "failed", "B5 场景下残留 user sending 必须一并转 failed")

        let stillSending = try await scalarInt(
            "SELECT count(*) FROM messages WHERE group_id = ? AND status = 'sending'", [groupID]
        )
        XCTAssertEqual(stillSending, 0)
    }

    // MARK: - S4-B-4 终态组一律不动

    func testS4B_4_TerminalGroupsUntouched() async throws {
        let completeID = try await seedGroup(userStatus: .sent, assistantStatus: .sent, turnIndex: 1)
        try await write("UPDATE message_groups SET status = 'complete', closed_at = 1 WHERE id = ?", [completeID])
        let failedID = try await seedGroup(userStatus: .sent, assistantStatus: .failed, turnIndex: 2)
        try await write("UPDATE message_groups SET status = 'failed', closed_at = 2 WHERE id = ?", [failedID])
        let abortedID = try await seedGroup(userStatus: .sent, assistantStatus: .canceled, turnIndex: 3)
        try await write("UPDATE message_groups SET status = 'aborted', closed_at = 3 WHERE id = ?", [abortedID])

        let report = try await makeOrchestrator(provider: StaticTextProvider())
            .recoverStaleTurns(conversationID: conversationID)

        XCTAssertEqual(report.closedGroups, 0, "终态组不得被再次关闭")
        XCTAssertEqual(report.repairedMessages, 0)

        let complete = try await groupStatus(completeID)
        let failed = try await groupStatus(failedID)
        let aborted = try await groupStatus(abortedID)
        XCTAssertEqual(complete, "complete")
        XCTAssertEqual(failed, "failed")
        XCTAssertEqual(aborted, "aborted")

        let closedAts = try await database.dbQueue.read { db in
            try Int64.fetchAll(db, sql: "SELECT closed_at FROM message_groups ORDER BY turn_index")
        }
        XCTAssertEqual(closedAts, [1, 2, 3], "closed_at 不得被改写")
    }

    // MARK: - S4-B-5 组内消息全部软删 → 关闭为 failed，且不复活消息

    func testS4B_5_OpenGroupWithAllMessagesDeletedBecomesFailed() async throws {
        let groupID = try await seedGroup(userStatus: .sent, assistantStatus: .sent)
        try await write(
            "UPDATE messages SET deleted_at = 1234 WHERE group_id = ?", [groupID]
        )

        let report = try await makeOrchestrator(provider: StaticTextProvider())
            .recoverStaleTurns(conversationID: conversationID)

        XCTAssertEqual(report.closedGroups, 1, "全软删的 open 组必须被关闭，不得永久遗留")
        let status = try await groupStatus(groupID)
        XCTAssertEqual(status, "failed", "无可恢复的可见内容时，最安全的终态是 failed")

        // 软删消息不得被复活，内容与状态保持原样
        let rows = try await database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT status, deleted_at FROM messages WHERE group_id = ? ORDER BY seq_in_group",
                arguments: [groupID]
            )
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(
            rows.allSatisfy { Int64.fromDatabaseValue($0["deleted_at"]) == 1234 },
            "deleted_at 必须保留，不得复活软删消息"
        )
        XCTAssertEqual(
            rows.map { String.fromDatabaseValue($0["status"]) },
            ["sent", "sent"],
            "不得改写软删消息的状态"
        )
        let closedAt = try await database.dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT closed_at FROM message_groups WHERE id = ?", arguments: [groupID])
        }
        XCTAssertNotNil(closedAt)
    }

    // MARK: - S4-C-1 分页 hasMore 与末页

    func testS4C_1_HasMoreFollowsCursor() async throws {
        let now = Clock.nowMillis()
        for index in 0..<5 {
            try await messages.insert(
                Message(
                    conversationID: conversationID, role: .user, text: "第\(index)条",
                    status: .sent, origin: .user, createdAt: now + Int64(index), sentAt: now
                )
            )
        }

        let first = try await messages.page(in: conversationID, before: nil, limit: 2)
        XCTAssertEqual(first.items.count, 2)
        XCTAssertTrue(first.hasMore)
        let firstCursor = try XCTUnwrap(first.nextCursor, "非末页必须给出游标")

        let second = try await messages.page(in: conversationID, before: firstCursor, limit: 2)
        XCTAssertEqual(second.items.count, 2)
        XCTAssertTrue(second.hasMore)
        let secondCursor = try XCTUnwrap(second.nextCursor)

        let third = try await messages.page(in: conversationID, before: secondCursor, limit: 2)
        XCTAssertEqual(third.items.count, 1)
        XCTAssertFalse(third.hasMore, "末页 hasMore 必须为 false")
        XCTAssertNil(third.nextCursor)

        let ids = (first.items + second.items + third.items).map(\.id)
        XCTAssertEqual(Set(ids).count, 5, "三页拼接必须覆盖全部且无重复")
    }

    // MARK: - S4-C-2 翻页期间新增消息不产生重复

    func testS4C_2_NewMessagesBetweenPagesDoNotDuplicate() async throws {
        let now = Clock.nowMillis()
        for index in 0..<4 {
            try await messages.insert(
                Message(
                    conversationID: conversationID, role: .user, text: "旧\(index)",
                    status: .sent, origin: .user, createdAt: now + Int64(index), sentAt: now
                )
            )
        }
        let first = try await messages.page(in: conversationID, before: nil, limit: 2)
        let firstCursor = try XCTUnwrap(first.nextCursor)

        // 翻页之间插入更新的消息
        try await messages.insert(
            Message(
                conversationID: conversationID, role: .user, text: "新消息",
                status: .sent, origin: .user, createdAt: now + 100, sentAt: now
            )
        )
        let second = try await messages.page(in: conversationID, before: firstCursor, limit: 10)

        let firstIDs = Set(first.items.map(\.id))
        XCTAssertTrue(second.items.allSatisfy { !firstIDs.contains($0.id) }, "跨页不得重复")
        XCTAssertEqual(first.items.count + second.items.count, 4, "新消息不应挤进旧游标之后的页")
    }

    // MARK: - S4-C-3 legacy 无组消息参与分页

    func testS4C_3_LegacyMessagesWithoutGroupIncluded() async throws {
        try await database.dbQueue.write { db in
            for index in 0..<3 {
                try db.execute(
                    sql: """
                    INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at, sent_at)
                    VALUES (?, ?, ?, 'user', 'text', ?, 'sent', 'user', ?, ?)
                    """,
                    arguments: [
                        "legacy-\(index)", "uuid-legacy-\(index)", conversationID,
                        "历史\(index)", Int64(index) + 1, Int64(index) + 1
                    ]
                )
            }
        }
        let page = try await messages.page(in: conversationID, before: nil, limit: 10)
        XCTAssertEqual(page.items.count, 3, "legacy 无组消息不得被分页丢弃")
        XCTAssertTrue(page.items.allSatisfy { $0.groupID == nil })
    }

    // MARK: - S4-D-1 重试中取消

    func testS4D_1_CancelDuringRetry() async throws {
        let sourceGroup = try await seedGroup(userStatus: .sent, assistantStatus: .failed)
        try await write("UPDATE message_groups SET status = 'failed', closed_at = 9 WHERE id = ?", [sourceGroup])
        let sourceUserID = try XCTUnwrap(
            try await scalarString("SELECT id FROM messages WHERE group_id = ? AND role = 'user'", [sourceGroup])
        )

        let gate = Latch()
        let started = Latch()
        let orchestrator = makeOrchestrator(provider: RetryBlockingProvider(gate: gate, started: started))
        let stream = orchestrator.retry(messageID: sourceUserID, conversationID: conversationID)
        let consumer = Task { await Self.collect(stream) }

        // 确定性同步：Provider 一旦被调用，说明 turnOpened 已产出、组已提交
        await started.wait()
        let active = await orchestrator.isTurnActive
        XCTAssertTrue(active, "重试必须进入活跃轮次")

        await orchestrator.cancelActiveTurn(owner: pageToken)
        let result = await consumer.value
        XCTAssertNil(result.error)
        XCTAssertTrue(Self.hasTerminal(result.events), "取消必须产生终态事件，实际：\(result.events)")

        // 旧组、旧消息不得被改动
        let sourceStatus = try await groupStatus(sourceGroup)
        XCTAssertEqual(sourceStatus, "failed")
        let sourceAssistant = try await scalarString(
            "SELECT status FROM messages WHERE group_id = ? AND role = 'assistant'", [sourceGroup]
        )
        XCTAssertEqual(sourceAssistant, "failed")

        // 新组必须 aborted，且无 open 组残留
        let openCount = try await scalarInt("SELECT count(*) FROM message_groups WHERE status = 'open'")
        XCTAssertEqual(openCount, 0, "取消后不得残留 open 组")
        let newStatus = try await scalarString(
            "SELECT status FROM message_groups WHERE id <> ? ORDER BY turn_index DESC LIMIT 1", [sourceGroup]
        )
        XCTAssertEqual(newStatus, "aborted")

        let newAssistant = try await scalarString(
            """
            SELECT status FROM messages
            WHERE group_id <> ? AND role = 'assistant' AND deleted_at IS NULL
            ORDER BY created_at DESC LIMIT 1
            """, [sourceGroup]
        )
        XCTAssertEqual(newAssistant, "canceled", "取消后 assistant 必须是 canceled")
        gate.signal()
    }

    // MARK: - S4-D-2 重复重试被拒且零写入

    func testS4D_2_DoubleRetryRejected() async throws {
        let sourceGroup = try await seedGroup(userStatus: .sent, assistantStatus: .failed)
        try await write("UPDATE message_groups SET status = 'failed', closed_at = 9 WHERE id = ?", [sourceGroup])
        let sourceUserID = try XCTUnwrap(
            try await scalarString("SELECT id FROM messages WHERE group_id = ? AND role = 'user'", [sourceGroup])
        )

        let gate = Latch()
        let started = Latch()
        let orchestrator = makeOrchestrator(provider: RetryBlockingProvider(gate: gate, started: started))
        let firstStream = orchestrator.retry(messageID: sourceUserID, conversationID: conversationID)
        let firstConsumer = Task { await Self.collect(firstStream) }

        await started.wait()
        let active = await orchestrator.isTurnActive
        XCTAssertTrue(active, "首轮重试必须进入活跃轮次")

        let before = try await scalarInt("SELECT count(*) FROM message_groups")
        let second = await Self.collect(orchestrator.retry(messageID: sourceUserID, conversationID: conversationID))
        XCTAssertNotNil(second.error, "并发第二次重试必须在首个事件前失败")
        XCTAssertTrue(second.events.isEmpty, "被拒的重试不得发出任何事件")
        let after = try await scalarInt("SELECT count(*) FROM message_groups")
        XCTAssertEqual(after, before, "被拒的重试不得写入任何组")

        await orchestrator.cancelActiveTurn(owner: pageToken)
        _ = await firstConsumer.value
        gate.signal()
    }
}

// MARK: - 测试替身

private struct StaticTextProvider: ChatModelProvider, @unchecked Sendable {
    var identifier: String { "static-text" }
    var capabilities: ModelCapabilities { [.text] }
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text("好的"))
            continuation.finish()
        }
    }
}

/// 已产出首段后挂起，直到放行（用于在"生成中"这一确定时点取消）
private struct RetryBlockingProvider: ChatModelProvider, @unchecked Sendable {
    var identifier: String { "retry-blocking" }
    var capabilities: ModelCapabilities { [.text] }
    let gate: Latch
    let started: Latch
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            started.signal()
            continuation.yield(.text("第一段"))
            Task {
                await gate.wait()
                continuation.finish()
            }
        }
    }
}

private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var signaled = false

    func signal() {
        lock.lock()
        guard !signaled else { lock.unlock(); return }
        signaled = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if signaled {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}

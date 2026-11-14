import XCTest
import Foundation
import GRDB
import DFCore
@testable import DFData
import DFOrchestration

/// B1-S3 生命周期与事务测试（B1-01~03、08~12、19、21~24）。
/// 全部使用真实 `AppDatabase` + 真实迁移 + 真实仓储；只有 Provider 是可控假实现。
final class ChatOrchestratorLifecycleTests: XCTestCase {
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
            .appendingPathComponent("OrchS3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        groups = GRDBMessageGroupRepository(database: database)
        turns = GRDBMessageTurnRepository(database: database)
        messages = GRDBMessageRepository(database: database)
        references = GRDBMessageReferenceRepository(database: database)
        units = GRDBContextUnitProvider(database: database)
        // 用真实仓储建会话（同时验证 A2 的 ensureMainConversation）
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

    // MARK: - 测试工具

    private func makeOrchestrator(
        provider: any ChatModelProvider,
        pageToken: UUID = UUID(),
        onProviderBuild: (@Sendable () -> Void)? = nil
    ) -> ChatOrchestratorImpl {
        let deps = ChatOrchestratorDependencies(
            groups: groups,
            turns: turns,
            messages: messages,
            references: references,
            units: units,
            makeProvider: {
                onProviderBuild?()
                return provider
            },
            makeRequest: { system, history in
                ChatRequest(model: "fake-model", systemPrompt: system, messages: history)
            }
        )
        return ChatOrchestratorImpl(dependencies: deps, pageToken: pageToken)
    }

    private func collect(
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

    private func allGroups() async throws -> [MessageGroup] {
        try await database.dbQueue.read { db in
            try MessageGroup.order(Column("turn_index").asc).fetchAll(db)
        }
    }

    // MARK: - B1-01 一次发送 = 1 组，turn 1，seq 0/1

    func testB1_01_SingleSendCreatesOneGroupAndPersistsBothMessages() async throws {
        let provider = ScriptedProvider(deltas: [.text("你"), .text("好")])
        let orchestrator = makeOrchestrator(provider: provider)
        let result = await collect(orchestrator.send(text: "在吗", conversationID: conversationID))
        XCTAssertNil(result.error, "正常路径不应抛错")

        let groupList = try await allGroups()
        XCTAssertEqual(groupList.count, 1)
        XCTAssertEqual(groupList[0].turnIndex, 1)
        XCTAssertEqual(groupList[0].status, .complete)

        let rows = try await messages.messages(inGroup: groupList[0].id)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].role, .user)
        XCTAssertEqual(rows[0].seqInGroup, 0)
        XCTAssertEqual(rows[1].role, .assistant)
        XCTAssertEqual(rows[1].seqInGroup, 1)
        XCTAssertEqual(rows[1].status, .sent)
        XCTAssertEqual(rows[1].text, "你好")
        XCTAssertNotNil(rows[1].sentAt)

        // 事件顺序：turnOpened → delta → delta → replaced → completed
        XCTAssertEqual(result.events.count, 5)
        guard case .turnOpened = result.events[0] else { return XCTFail("首事件必须是 turnOpened") }
        XCTAssertEqual(result.events[1], .assistantDelta("你"))
        XCTAssertEqual(result.events[2], .assistantDelta("好"))
        XCTAssertEqual(result.events[3], .assistantReplaced("你好"))
        guard case .turnCompleted = result.events[4] else {
            return XCTFail("末事件必须是 turnCompleted")
        }
    }

    // MARK: - B1-02 连续两次发送 = 2 组，旧组不追加

    func testB1_02_SecondSendCreatesNewGroupWithoutTouchingOldOne() async throws {
        let orchestrator1 = makeOrchestrator(provider: ScriptedProvider(deltas: [.text("第一轮")]))
        _ = await collect(orchestrator1.send(text: "问题一", conversationID: conversationID))

        let orchestrator2 = makeOrchestrator(provider: ScriptedProvider(deltas: [.text("第二轮")]))
        _ = await collect(orchestrator2.send(text: "问题二", conversationID: conversationID))

        let groupList = try await allGroups()
        XCTAssertEqual(groupList.count, 2)
        XCTAssertEqual(groupList.map(\.turnIndex), [1, 2])

        let first = try await messages.messages(inGroup: groupList[0].id)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first[0].text, "问题一")
        XCTAssertEqual(first[1].text, "第一轮")

        let second = try await messages.messages(inGroup: groupList[1].id)
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(second[0].seqInGroup, 0)
        XCTAssertEqual(second[1].seqInGroup, 1)
    }

    // MARK: - B1-03 已有 open 组时拒绝，且不调用 Provider

    func testB1_03_ExistingOpenGroupRejectsWithoutCallingProvider() async throws {
        let counter = CallCounter()
        let group = MessageGroup(conversationID: conversationID, turnIndex: 1)
        let user = Message(
            conversationID: conversationID, role: .user, text: "旧",
            status: .sent, origin: .user
        )
        let assistant = Message(
            conversationID: conversationID, role: .assistant, text: "",
            status: .sending, origin: .reply
        )
        _ = try await groups.openTurn(
            OpenTurnRequest(group: group, userMessage: user, assistantMessage: assistant)
        )

        let before = try await countRows()
        let orchestrator = makeOrchestrator(provider: ScriptedProvider(deltas: []), onProviderBuild: {
            counter.increment()
        })
        let result = await collect(orchestrator.send(text: "新问题", conversationID: conversationID))

        XCTAssertTrue(result.error is ChatOrchestrationError)
        if case .groupAlreadyOpen = (result.error as? ChatOrchestrationError) {} else {
            XCTFail("应抛出 groupAlreadyOpen")
        }
        XCTAssertEqual(counter.value, 0, "事务 A 之前失败，不得调用 Provider")
        let after = try await countRows()
        XCTAssertEqual(after, before, "库内不得新增行")
    }

    // MARK: - B1-08 空回复 → failed / failed

    func testB1_08_EmptyReplyFailsGroup() async throws {
        let orchestrator = makeOrchestrator(provider: ScriptedProvider(deltas: [.text("   ")]))
        let result = await collect(orchestrator.send(text: "在吗", conversationID: conversationID))
        XCTAssertNil(result.error, "turnOpened 之后的失败不得 throw")

        guard let last = result.events.last, case let .turnFailed(_, _, reason) = last else {
            return XCTFail("末事件应为 turnFailed")
        }
        XCTAssertEqual(reason, "empty_reply")

        let group = try await allGroups()[0]
        XCTAssertEqual(group.status, .failed)
        XCTAssertNotNil(group.closedAt)
        let rows = try await messages.messages(inGroup: group.id)
        XCTAssertEqual(rows[1].status, .failed)
    }

    // MARK: - B1-09 Provider 抛错 → failed，保留已生成正文

    func testB1_09_ProviderErrorFailsGroupAndKeepsPartialText() async throws {
        let provider = ScriptedProvider(
            deltas: [.text("已经生成的一半")],
            error: DFError.network("连接中断")
        )
        let orchestrator = makeOrchestrator(provider: provider)
        let result = await collect(orchestrator.send(text: "在吗", conversationID: conversationID))
        XCTAssertNil(result.error)

        guard let last = result.events.last, case let .turnFailed(_, _, reason) = last else {
            return XCTFail("末事件应为 turnFailed")
        }
        XCTAssertTrue(reason.contains("网络"), "原因应保留模型错误信息：\(reason)")

        let group = try await allGroups()[0]
        XCTAssertEqual(group.status, .failed)
        let rows = try await messages.messages(inGroup: group.id)
        XCTAssertEqual(rows[1].status, .failed)
        XCTAssertEqual(rows[1].text, "已经生成的一半", "失败也要保留已生成正文")
    }

    // MARK: - B1-10 取消 → aborted / canceled，保留正文，不写 sent_at

    func testB1_10_CancelMarksAbortedAndCanceled() async throws {
        let provider = SlowProvider()
        let token = UUID()
        let orchestrator = makeOrchestrator(provider: provider, pageToken: token)
        let stream = orchestrator.send(text: "讲个长故事", conversationID: conversationID)

        let collector = Task { await collect(stream) }
        // 等首段到达，确保已进入 streaming
        try await Task.sleep(nanoseconds: 80_000_000)
        await orchestrator.cancelActiveTurn(owner: token)
        let result = await collector.value
        XCTAssertNil(result.error)

        guard let last = result.events.last, case .turnCancelled = last else {
            return XCTFail("末事件应为 turnCancelled，实际：\(String(describing: result.events.last))")
        }
        let group = try await allGroups()[0]
        XCTAssertEqual(group.status, .aborted)
        XCTAssertNotNil(group.closedAt)
        let rows = try await messages.messages(inGroup: group.id)
        XCTAssertEqual(rows[1].status, .canceled)
        XCTAssertNil(rows[1].sentAt)
        XCTAssertEqual(rows[1].text, "第一段", "取消要保留已生成正文")
    }

    // MARK: - B1-11 对终态组取消 → no-op，库不变

    func testB1_11_CancelAfterTerminalIsNoOp() async throws {
        let token = UUID()
        let orchestrator = makeOrchestrator(
            provider: ScriptedProvider(deltas: [.text("完成")]),
            pageToken: token
        )
        _ = await collect(orchestrator.send(text: "问题", conversationID: conversationID))
        let before = try await allGroups()[0]

        await orchestrator.cancelActiveTurn(owner: token)
        await orchestrator.cancelActiveTurn(owner: token)

        let after = try await allGroups()[0]
        XCTAssertEqual(after.status, .complete)
        XCTAssertEqual(after.closedAt, before.closedAt, "终态组不得被二次改写")
    }

    // MARK: - B1-12 重试：新组 + 新 user 副本；旧组完全不变

    func testB1_12_RetryCreatesNewGroupAndKeepsOldRowsIntact() async throws {
        let failing = ScriptedProvider(deltas: [.text("旧回复")], error: DFError.network("失败"))
        let first = makeOrchestrator(provider: failing)
        _ = await collect(first.send(text: "原始提问", conversationID: conversationID))

        let oldGroup = try await allGroups()[0]
        let oldRows = try await messages.messages(inGroup: oldGroup.id)
        let oldUserID = oldRows[0].id
        let oldAssistantID = oldRows[1].id
        let oldAssistantText = oldRows[1].text
        let oldClosedAt = oldGroup.closedAt

        let second = makeOrchestrator(provider: ScriptedProvider(deltas: [.text("新回复")]))
        let result = await collect(
            second.retry(messageID: oldAssistantID, conversationID: conversationID)
        )
        XCTAssertNil(result.error)

        let groupList = try await allGroups()
        XCTAssertEqual(groupList.count, 2)
        let newGroup = groupList[1]
        XCTAssertEqual(newGroup.turnIndex, 2)

        // 旧组与旧消息完全不变
        let oldAfter = try await allGroups()[0]
        XCTAssertEqual(oldAfter.status, .failed)
        XCTAssertEqual(oldAfter.closedAt, oldClosedAt)
        let oldRowsAfter = try await messages.messages(inGroup: oldGroup.id)
        XCTAssertEqual(oldRowsAfter[0].id, oldUserID)
        XCTAssertEqual(oldRowsAfter[1].id, oldAssistantID)
        XCTAssertEqual(oldRowsAfter[1].text, oldAssistantText)
        XCTAssertEqual(oldRowsAfter[1].status, .failed)
        XCTAssertNil(oldRowsAfter[1].deletedAt, "旧消息不得被软删")

        // 新组：新 user 副本（新 id、同文本）+ 新 assistant
        let newRows = try await messages.messages(inGroup: newGroup.id)
        XCTAssertEqual(newRows.count, 2)
        XCTAssertNotEqual(newRows[0].id, oldUserID, "重试必须新建 user 副本")
        XCTAssertEqual(newRows[0].text, "原始提问")
        XCTAssertEqual(newRows[1].text, "新回复")

        // 不复制旧引用
        let copied = try await references.references(for: [newRows[1].id])
        XCTAssertTrue(copied.isEmpty, "不得自动复制旧 assistant 的引用关系")
    }

    // MARK: - B1-19 取消幂等：重复调用不产生第二次状态转换

    func testB1_19_CancelIsIdempotent() async throws {
        let token = UUID()
        let orchestrator = makeOrchestrator(provider: SlowProvider(), pageToken: token)
        let stream = orchestrator.send(text: "长故事", conversationID: conversationID)
        let collector = Task { await collect(stream) }

        try await Task.sleep(nanoseconds: 80_000_000)
        await orchestrator.cancelActiveTurn(owner: token)
        let result = await collector.value
        XCTAssertNil(result.error)

        let closedAt = try await allGroups()[0].closedAt
        await orchestrator.cancelActiveTurn(owner: token)
        await orchestrator.cancelActiveTurn(owner: token)

        let group = try await allGroups()[0]
        XCTAssertEqual(group.status, .aborted)
        XCTAssertEqual(group.closedAt, closedAt, "重复取消不得再次写 closed_at")
        XCTAssertEqual(result.events.filter { isTerminal($0) }.count, 1)
    }

    // MARK: - B1-21 turnOpened 之后失败不 throw

    func testB1_21_NoThrowAfterTurnOpened() async throws {
        let failing = ScriptedProvider(deltas: [.text("片段")], error: DFError.http(status: 500, message: "boom"))
        let orchestrator = makeOrchestrator(provider: failing)
        let result = await collect(orchestrator.send(text: "在吗", conversationID: conversationID))

        XCTAssertNil(result.error, "turnOpened 之后不得 throw")
        XCTAssertTrue(result.events.contains { if case .turnOpened = $0 { return true }; return false })
        XCTAssertTrue(isTerminal(result.events.last))
    }

    // MARK: - B1-22 完成 vs 取消竞态：只有一个终态

    func testB1_22_FinalizeAndCancelYieldSingleTerminal() async throws {
        let gate = Gate()
        let turnRepo = GatedTurnRepository(base: turns, gate: gate, delayBeforeFinalize: 0.15)
        let token = UUID()
        let deps = ChatOrchestratorDependencies(
            groups: groups,
            turns: turnRepo,
            messages: messages,
            references: references,
            units: units,
            makeProvider: { ScriptedProvider(deltas: [.text("正文")]) },
            makeRequest: { system, history in
                ChatRequest(model: "fake-model", systemPrompt: system, messages: history)
            }
        )
        let orchestrator = ChatOrchestratorImpl(dependencies: deps, pageToken: token)
        let stream = orchestrator.send(text: "问题", conversationID: conversationID)
        let collector = Task { await collect(stream) }

        // 等进入 streaming 后立刻取消，使取消与定稿争抢同一个 open 组
        try await Task.sleep(nanoseconds: 60_000_000)
        await orchestrator.cancelActiveTurn(owner: token)
        let result = await collector.value
        XCTAssertNil(result.error)

        let terminals = result.events.filter { isTerminal($0) }
        XCTAssertEqual(terminals.count, 1, "同一轮只能有一个终态事件")

        let group = try await allGroups()[0]
        XCTAssertNotEqual(group.status, .open, "不得遗留 open 组")
        switch terminals[0] {
        case .turnCompleted:
            XCTAssertEqual(group.status, .complete)
        case .turnCancelled:
            XCTAssertEqual(group.status, .aborted)
        case .turnFailed:
            XCTAssertEqual(group.status, .failed)
        default:
            XCTFail("非终态事件")
        }
    }

    // MARK: - B1-23 turnOpened 之前失败：throw 且库内零新增

    func testB1_23_PreflightFailureThrowsWithoutWrites() async throws {
        let counter = CallCounter()
        let orchestrator = makeOrchestrator(
            provider: ScriptedProvider(deltas: []),
            onProviderBuild: { counter.increment() }
        )
        let result = await collect(orchestrator.send(text: "   ", conversationID: conversationID))

        XCTAssertTrue(result.error is ChatOrchestrationError)
        if case .emptyInput = (result.error as? ChatOrchestrationError) {} else {
            XCTFail("空输入应抛 emptyInput")
        }
        XCTAssertTrue(result.events.isEmpty)
        let groupsCount = try await countGroups()
        let messagesCount = try await countMessages()
        XCTAssertEqual(groupsCount, 0)
        XCTAssertEqual(messagesCount, 0)
        XCTAssertEqual(counter.value, 0)
    }

    // MARK: - B1-24 opening 期间取消：不遗留 open 组

    func testB1_24_CancelDuringOpenTurnLeavesNoOpenGroup() async throws {
        let gate = Gate()
        let groupRepo = GatedGroupRepository(base: groups, gate: gate)
        let token = UUID()
        let deps = ChatOrchestratorDependencies(
            groups: groupRepo,
            turns: turns,
            messages: messages,
            references: references,
            units: units,
            makeProvider: { ScriptedProvider(deltas: [.text("不该出现")]) },
            makeRequest: { system, history in
                ChatRequest(model: "fake-model", systemPrompt: system, messages: history)
            }
        )
        let orchestrator = ChatOrchestratorImpl(dependencies: deps, pageToken: token)
        let stream = orchestrator.send(text: "问题", conversationID: conversationID)
        let collector = Task { await collect(stream) }

        // 等 openTurn 真正进入，再取消
        try await gate.waitForEntry()
        await orchestrator.cancelActiveTurn(owner: token)
        await gate.release()
        let result = await collector.value
        XCTAssertNil(result.error)

        let groupList = try await allGroups()
        XCTAssertEqual(groupList.count, 1)
        XCTAssertEqual(groupList[0].status, .aborted)
        let openCount = try await countOpenGroups()
        XCTAssertEqual(openCount, 0, "不得遗留无人处理的 open 组")

        let rows = try await messages.messages(inGroup: groupList[0].id)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].status, .canceled)
        XCTAssertNil(rows[1].sentAt)

        let terminals = result.events.filter { isTerminal($0) }
        XCTAssertEqual(terminals.count, 1)
        guard case .turnCancelled = terminals[0] else { return XCTFail("opening 取消应产生 turnCancelled") }
    }

    // MARK: - 小工具

    private func isTerminal(_ event: OrchestratorEvent?) -> Bool {
        switch event {
        case .turnCompleted, .turnFailed, .turnCancelled: return true
        default: return false
        }
    }

    private func countGroups() async throws -> Int {
        try await database.dbQueue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message_groups") ?? 0 }
    }

    private func countMessages() async throws -> Int {
        try await database.dbQueue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM messages") ?? 0 }
    }

    private func countOpenGroups() async throws -> Int {
        try await database.dbQueue.read {
            try Int.fetchOne($0, sql: "SELECT count(*) FROM message_groups WHERE status = 'open'") ?? 0
        }
    }

    private func countRows() async throws -> Int {
        let groupsCount = try await countGroups()
        let messagesCount = try await countMessages()
        return groupsCount + messagesCount
    }
}

// MARK: - 测试替身

/// 脚本化 Provider：按顺序吐出增量，可选在末尾抛错。
struct ScriptedProvider: ChatModelProvider, @unchecked Sendable {
    var identifier: String { "scripted" }
    var capabilities: ModelCapabilities { [.text] }
    let deltas: [ChatDelta]
    let error: Error?

    init(deltas: [ChatDelta], error: Error? = nil) {
        self.deltas = deltas
        self.error = error
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            for delta in deltas { continuation.yield(delta) }
            if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        }
    }
}

/// 慢速 Provider：首段后长时间等待，用于验证流式取消。
struct SlowProvider: ChatModelProvider {
    var identifier: String { "slow" }
    var capabilities: ModelCapabilities { [.text] }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.text("第一段"))
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    try Task.checkCancellation()
                    continuation.yield(.text("第二段"))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    func increment() {
        lock.lock(); storage += 1; lock.unlock()
    }
}

/// 双信号闸门：测试用它精确控制"事务执行中"这一时点。
final class Gate: @unchecked Sendable {
    let entry = AsyncStreamSignal()
    let releaseSignal = AsyncStreamSignal()

    /// 测试侧：等仓储真正进入 openTurn
    func waitForEntry() async { await entry.wait() }
    /// 仓储侧：通知测试已进入，然后阻塞等待放行
    func holdUntilReleased() async {
        entry.signal()
        await releaseSignal.wait()
    }
    /// 测试侧：放行
    func release() { releaseSignal.signal() }
}

/// 简单的异步一次性信号（避免依赖 XCTestExpectation 的同步语义）。
final class AsyncStreamSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func signal() {
        lock.lock()
        signaled = true
        let waiting = continuations
        continuations.removeAll()
        lock.unlock()
        waiting.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if signaled {
                lock.unlock()
                continuation.resume()
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// 门控组仓储：只在 `openTurn` 前后加闸，其余方法原样委托真实仓储。
struct GatedGroupRepository: MessageGroupRepository {
    let base: GRDBMessageGroupRepository
    let gate: Gate

    func openTurn(_ request: OpenTurnRequest) async throws -> MessageGroup {
        await gate.holdUntilReleased()
        return try await base.openTurn(request)
    }

    func group(id: String) async throws -> MessageGroup? { try await base.group(id: id) }
    func openGroup(in conversationID: String) async throws -> MessageGroup? {
        try await base.openGroup(in: conversationID)
    }
    func maxTurnIndex(in conversationID: String) async throws -> Int? {
        try await base.maxTurnIndex(in: conversationID)
    }
    func maxSeq(inGroup groupID: String) async throws -> Int? {
        try await base.maxSeq(inGroup: groupID)
    }
    func closeGroup(id: String, status: MessageGroupStatus, closedAt: Int64) async throws {
        try await base.closeGroup(id: id, status: status, closedAt: closedAt)
    }
    func cancelTurn(groupID: String, assistantMessageID: String, closedAt: Int64) async throws {
        try await base.cancelTurn(groupID: groupID, assistantMessageID: assistantMessageID, closedAt: closedAt)
    }
    func repairStaleSending(in conversationID: String) async throws -> Int {
        try await base.repairStaleSending(in: conversationID)
    }
}

/// 门控定稿仓储：在 `finalizeTurn` 前延迟，用于制造"完成 vs 取消"竞态窗口。
struct GatedTurnRepository: MessageTurnRepository {
    let base: GRDBMessageTurnRepository
    let gate: Gate
    let delayBeforeFinalize: Double

    func finalizeTurn(_ request: FinalizeTurnRequest) async throws {
        try? await Task.sleep(nanoseconds: UInt64(delayBeforeFinalize * 1_000_000_000))
        try await base.finalizeTurn(request)
    }

    func failTurn(groupID: String, assistantMessageID: String, text: String?, closedAt: Int64) async throws {
        try await base.failTurn(
            groupID: groupID, assistantMessageID: assistantMessageID, text: text, closedAt: closedAt
        )
    }
}

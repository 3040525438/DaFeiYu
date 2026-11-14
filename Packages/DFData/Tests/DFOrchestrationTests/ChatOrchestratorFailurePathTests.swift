import XCTest
import Foundation
import GRDB
import DFCore
@testable import DFData
import DFOrchestration

/// B1-S3 修复轮测试：G1~G6。
/// 全部使用真实 `AppDatabase` + 真实迁移 + 真实仓储；
/// 只有"制造失败的装饰器"与 Provider 是测试替身。
final class ChatOrchestratorFailurePathTests: XCTestCase {
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
            .appendingPathComponent("OrchFix-\(UUID().uuidString)", isDirectory: true)
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

    private func makeOrchestrator(
        provider: any ChatModelProvider,
        pageToken: UUID = UUID(),
        messagesRepo: (any MessageRepository)? = nil,
        groupsRepo: (any MessageGroupRepository)? = nil,
        turnsRepo: (any MessageTurnRepository)? = nil
    ) -> ChatOrchestratorImpl {
        let deps = ChatOrchestratorDependencies(
            groups: groupsRepo ?? groups,
            turns: turnsRepo ?? turns,
            messages: messagesRepo ?? messages,
            references: references,
            units: units,
            makeProvider: { provider },
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

    private func onlyGroup() async throws -> MessageGroup {
        let group = try await database.dbQueue.read { db in
            try MessageGroup.order(Column("turn_index").asc).fetchOne(db)
        }
        return try XCTUnwrap(group, "数据库中没有任何消息组（openTurn 未提交或已失败）")
    }

    private func groupRows(in groupID: String) async throws -> [Message] {
        try await messages.messages(inGroup: groupID)
    }

    private func isTerminal(_ event: OrchestratorEvent) -> Bool {
        switch event {
        case .turnCompleted, .turnFailed, .turnCancelled: return true
        default: return false
        }
    }

    /// 边收边记，并允许测试等待"已经看到首段增量"这一确定性时点（不使用 sleep）。
    private static func consume(
        _ stream: AsyncThrowingStream<OrchestratorEvent, Error>,
        into recorder: EventRecorder
    ) async {
        do {
            for try await event in stream { recorder.append(event) }
            recorder.finish(error: nil)
        } catch {
            recorder.finish(error: error)
        }
    }

    // MARK: - G1 正文更新失败 + 取消成功

    func testG1_TextSaveFailureKeepsCancelAndReportsDiagnostic() async throws {
        let token = UUID()
        let failingMessages = FailingMessageRepository(base: messages, failTextUpdate: true)
        let provider = GatedProvider(firstChunk: "第一段")
        let orchestrator = makeOrchestrator(
            provider: provider, pageToken: token, messagesRepo: failingMessages
        )
        let stream = orchestrator.send(text: "讲个故事", conversationID: conversationID)
        let recorder = EventRecorder()
        let collector = Task { await Self.consume(stream, into: recorder) }
        let firstSignal = await recorder.waitForDeltaOrEnd()
        XCTAssertEqual(firstSignal, .delta, "取消前必须已收到 assistantDelta，实际：\(firstSignal)")

        await orchestrator.cancelActiveTurn(owner: token)
        provider.release()
        await collector.value
        let result = (events: recorder.all, error: recorder.failure)
        XCTAssertNil(result.error, "turnOpened 之后不得 throw")

        // 事件：取消事务成功 → turnCancelled（唯一终态）
        let terminals = result.events.filter(isTerminal)
        XCTAssertEqual(terminals.count, 1)
        XCTAssertTrue(result.events.contains {
            if case .turnCancelled = $0 { return true }; return false
        })

        // 库内真实状态：组 aborted、assistant canceled、正文丢失
        let group = try await onlyGroup()
        XCTAssertEqual(group.status, .aborted)
        let rows = try await groupRows(in: group.id)
        XCTAssertEqual(rows[1].status, .canceled)
        XCTAssertEqual(rows[1].text, "", "更新失败时正文确实未落库")

        // 不得静默：诊断信息必须可读
        let diagnostic = await orchestrator.lastDiagnostic
        XCTAssertNotNil(diagnostic)
        XCTAssertTrue(
            diagnostic?.contains("取消成功，但正文未完整保存") == true,
            "必须命中「取消事务成功、正文未完整保存」这条路径，实际诊断：\(diagnostic ?? "nil")"
        )
    }

    // MARK: - G2 取消事务失败且库仍 open

    func testG2_CancelFailureOnOpenGroupReportsRecoveryPending() async throws {
        let token = UUID()
        let failingGroups = FailingCancelGroupRepository(base: groups)
        let provider = GatedProvider(firstChunk: "第一段")
        let orchestrator = makeOrchestrator(
            provider: provider, pageToken: token, groupsRepo: failingGroups
        )
        let stream = orchestrator.send(text: "讲个故事", conversationID: conversationID)
        let recorder = EventRecorder()
        let collector = Task { await Self.consume(stream, into: recorder) }
        let firstSignal = await recorder.waitForDeltaOrEnd()
        XCTAssertEqual(firstSignal, .delta, "取消前必须已收到 assistantDelta，实际：\(firstSignal)")

        await orchestrator.cancelActiveTurn(owner: token)
        provider.release()
        await collector.value
        let result = (events: recorder.all, error: recorder.failure)
        XCTAssertNil(result.error)

        // 绝不能发 turnCancelled（库内没有 aborted）
        XCTAssertFalse(result.events.contains {
            if case .turnCancelled = $0 { return true }; return false
        })
        XCTAssertEqual(result.events.filter(isTerminal).count, 0, "库未终结时不得有任何终态事件")

        guard case let .turnRecoveryPending(_, _, reason)? = result.events.last else {
            return XCTFail("末事件应为 turnRecoveryPending，实际：\(String(describing: result.events.last))")
        }
        XCTAssertTrue(reason.contains("cancel_failed"), "实际：\(reason)")

        // 库内：组仍 open、assistant 仍 sending、正文已保存
        let group = try await onlyGroup()
        XCTAssertEqual(group.status, .open)
        XCTAssertNil(group.closedAt)
        let rows = try await groupRows(in: group.id)
        XCTAssertEqual(rows[1].status, .sending)
        XCTAssertEqual(rows[1].text, "第一段")
    }

    // MARK: - G3 正文保存 + 终结补偿双失败

    func testG3_BothFailuresYieldRecoveryPendingNotFakeTerminal() async throws {
        let token = UUID()
        let failingMessages = FailingMessageRepository(base: messages, failTextUpdate: true)
        let failingGroups = FailingCancelGroupRepository(base: groups)
        let provider = GatedProvider(firstChunk: "第一段")
        let orchestrator = makeOrchestrator(
            provider: provider, pageToken: token,
            messagesRepo: failingMessages, groupsRepo: failingGroups
        )
        let stream = orchestrator.send(text: "讲个故事", conversationID: conversationID)
        let recorder = EventRecorder()
        let collector = Task { await Self.consume(stream, into: recorder) }
        let firstSignal = await recorder.waitForDeltaOrEnd()
        XCTAssertEqual(firstSignal, .delta, "取消前必须已收到 assistantDelta，实际：\(firstSignal)")

        await orchestrator.cancelActiveTurn(owner: token)
        provider.release()
        await collector.value
        let result = (events: recorder.all, error: recorder.failure)
        XCTAssertNil(result.error)

        // 三个终态一个都不能出现
        XCTAssertEqual(result.events.filter(isTerminal).count, 0)
        XCTAssertEqual(result.events.filter {
            if case .turnRecoveryPending = $0 { return true }; return false
        }.count, 1, "必须恰好一个恢复待处理事件")

        // 库内仍可恢复：open + sending
        let group = try await onlyGroup()
        XCTAssertEqual(group.status, .open)
        let rows = try await groupRows(in: group.id)
        XCTAssertEqual(rows[1].status, .sending)

        // 诊断必须同时包含两条失败原因
        let diagnostic = await orchestrator.lastDiagnostic ?? ""
        XCTAssertTrue(diagnostic.contains("cancel_failed"), "实际：\(diagnostic)")
        XCTAssertTrue(diagnostic.contains("text_save_failed"), "实际：\(diagnostic)")
    }

    // MARK: - G4 owner 不匹配：零写入零副作用

    func testG4_OwnerMismatchIsNoOp() async throws {
        let token = UUID()
        let provider = GatedProvider(firstChunk: "第一段")
        let orchestrator = makeOrchestrator(provider: provider, pageToken: token)
        let stream = orchestrator.send(text: "讲个故事", conversationID: conversationID)
        let recorder = EventRecorder()
        let collector = Task { await Self.consume(stream, into: recorder) }
        let firstSignal = await recorder.waitForDeltaOrEnd()
        XCTAssertEqual(firstSignal, .delta, "取消前必须已收到 assistantDelta，实际：\(firstSignal)")

        // 错误 token 连续取消两次
        await orchestrator.cancelActiveTurn(owner: UUID())
        await orchestrator.cancelActiveTurn(owner: UUID())

        // 立即查库：仍 open / sending，无 closed_at
        let during = try await onlyGroup()
        XCTAssertEqual(during.status, .open, "owner 不匹配不得改变组状态")
        XCTAssertNil(during.closedAt)
        let duringRows = try await groupRows(in: during.id)
        XCTAssertEqual(duringRows[1].status, .sending)

        // 放行后必须正常完成
        provider.release()
        await collector.value
        let result = (events: recorder.all, error: recorder.failure)
        XCTAssertNil(result.error)
        guard let last = result.events.last, case .turnCompleted = last else {
            return XCTFail("owner 不匹配不得影响本轮完成，实际末事件：\(String(describing: result.events.last))")
        }
        let after = try await onlyGroup()
        XCTAssertEqual(after.status, .complete)
        let afterRows = try await groupRows(in: after.id)
        XCTAssertEqual(afterRows[1].status, .sent)
    }

    // MARK: - G5-A 数据库层真实竞争：finalize vs cancel 同一 open 组

    func testG5A_ConcurrentFinalizeAndCancelOnlyOneWinsInDatabase() async throws {
        let opened = try await openGroupWithAssistant()
        let barrier = AsyncBarrier(parties: 2)

        async let finalizeSucceeded = Self.attemptFinalize(
            FinalizeTurnRequest(
                groupID: opened.group.id,
                assistantMessageID: opened.assistantID,
                text: "定稿正文",
                assistantStatus: .sent,
                sentAt: 9000,
                replyToID: nil,
                references: [],
                groupStatus: .complete,
                closedAt: 9000
            ),
            barrier: barrier,
            repo: turns!
        )
        async let cancelSucceeded = Self.attemptCancel(
            groupID: opened.group.id,
            assistantMessageID: opened.assistantID,
            barrier: barrier,
            repo: groups!
        )

        let (finalized, cancelled) = await (finalizeSucceeded, cancelSucceeded)
        XCTAssertNotEqual(finalized, cancelled, "两个事务必须恰有一个成功")

        let group = try await onlyGroup()
        let rows = try await groupRows(in: group.id)
        XCTAssertNotEqual(group.status, .open, "不得残留 open 组")
        if finalized {
            XCTAssertEqual(group.status, .complete)
            XCTAssertEqual(rows[1].status, .sent)
            XCTAssertEqual(rows[1].text, "定稿正文")
            XCTAssertEqual(rows[1].sentAt, 9000)
        } else {
            XCTAssertEqual(group.status, .aborted)
            XCTAssertEqual(rows[1].status, .canceled)
            XCTAssertNil(rows[1].sentAt, "取消路径不得写 sent_at")
        }
    }

    // MARK: - G5-B 编排层：定稿进行中收到取消，只产生一个终态

    func testG5B_CancelDuringFinalizeKeepsSingleTerminal() async throws {
        let token = UUID()
        let gate = FinalizeGate()
        let gatedTurns = BlockingFinalizeTurnRepository(base: turns, gate: gate)
        let orchestrator = makeOrchestrator(
            provider: ScriptedProvider(deltas: [.text("正文")]),
            pageToken: token,
            turnsRepo: gatedTurns
        )
        let stream = orchestrator.send(text: "问题", conversationID: conversationID)
        let collector = Task { await collect(stream) }

        // 不用 sleep：等 finalize 真正进入后，再取消，再放行
        await gate.waitForEntry()
        await orchestrator.cancelActiveTurn(owner: token)
        gate.release()
        let result = await collector.value
        XCTAssertNil(result.error)

        let terminals = result.events.filter(isTerminal)
        XCTAssertEqual(terminals.count, 1, "只允许一个终态事件")

        let group = try await onlyGroup()
        let rows = try await groupRows(in: group.id)
        switch terminals[0] {
        case .turnCompleted:
            XCTAssertEqual(group.status, .complete)
            XCTAssertEqual(rows[1].status, .sent)
            XCTAssertEqual(rows[1].text, "正文")
            XCTAssertNotNil(rows[1].sentAt)
        case .turnCancelled:
            XCTAssertEqual(group.status, .aborted)
            XCTAssertEqual(rows[1].status, .canceled)
            XCTAssertNil(rows[1].sentAt)
        case .turnFailed:
            XCTAssertEqual(group.status, .failed)
        default:
            XCTFail("终态事件的库状态必须与之一致")
        }
    }

    // MARK: - G6-1 重试新建副本：client_uuid / seq / 旧数据不变

    func testG6A_RetryCreatesNewCopyWithFreshIdentifiers() async throws {
        let failing = ScriptedProvider(deltas: [.text("旧回复")], error: DFError.network("失败"))
        let first = makeOrchestrator(provider: failing)
        let firstRound = await collect(first.send(text: "原始提问", conversationID: conversationID))
        guard firstRound.error == nil else {
            return XCTFail("首轮失败必须通过事件表达，实际流错误：\(String(describing: firstRound.error))")
        }

        let oldGroup = try await onlyGroup()
        let oldRows = try await groupRows(in: oldGroup.id)
        let oldUser = oldRows[0]
        let oldAssistant = oldRows[1]

        let second = makeOrchestrator(provider: ScriptedProvider(deltas: [.text("新回复")]))
        let result = await collect(
            second.retry(messageID: oldAssistant.id, conversationID: conversationID)
        )
        XCTAssertNil(result.error)

        let fetchedNew = try await database.dbQueue.read { db in
            try MessageGroup.order(Column("turn_index").desc).fetchOne(db)
        }
        let newGroup = try XCTUnwrap(fetchedNew, "重试必须创建新组")
        XCTAssertEqual(newGroup.turnIndex, oldGroup.turnIndex + 1, "新组必须为 N+1")

        let newRows = try await groupRows(in: newGroup.id)
        XCTAssertEqual(newRows.count, 2)
        XCTAssertNotEqual(newRows[0].id, oldUser.id, "必须新建 user 副本（新 id）")
        XCTAssertNotEqual(newRows[0].clientUUID, oldUser.clientUUID, "必须新建 client_uuid")
        XCTAssertEqual(newRows[0].text, "原始提问")
        XCTAssertEqual(newRows[0].seqInGroup, 0, "seq 由仓储分配为 0")
        XCTAssertEqual(newRows[1].seqInGroup, 1, "seq 由仓储分配为 1")
        XCTAssertEqual(newRows[1].text, "新回复")

        // 旧组与旧消息逐项不变
        let oldAfter = try await onlyGroup()
        let oldRowsAfter = try await groupRows(in: oldGroup.id)
        XCTAssertEqual(oldAfter.status, .failed)
        XCTAssertEqual(oldRowsAfter[0].id, oldUser.id)
        XCTAssertEqual(oldRowsAfter[0].clientUUID, oldUser.clientUUID)
        XCTAssertEqual(oldRowsAfter[1].id, oldAssistant.id)
        XCTAssertEqual(oldRowsAfter[1].status, .failed)
        XCTAssertNil(oldRowsAfter[1].deletedAt)
        let copiedRefs = try await references.references(for: [newRows[1].id])
        XCTAssertTrue(copiedRefs.isEmpty)
    }

    // MARK: - G6-2 重试失败：新组正确终结，旧组不受影响

    func testG6B_RetryFailureTerminatesNewGroupOnly() async throws {
        let firstFail = ScriptedProvider(deltas: [.text("旧回复")], error: DFError.network("失败一"))
        let firstRound = await collect(
            makeOrchestrator(provider: firstFail).send(text: "原始提问", conversationID: conversationID)
        )
        guard firstRound.error == nil else {
            return XCTFail("首轮失败必须通过事件表达，实际流错误：\(String(describing: firstRound.error))")
        }
        let oldGroup = try await onlyGroup()
        let oldAssistantID = try await groupRows(in: oldGroup.id)[1].id

        let secondFail = ScriptedProvider(deltas: [.text("半截")], error: DFError.http(status: 500, message: "boom"))
        let result = await collect(
            makeOrchestrator(provider: secondFail).retry(
                messageID: oldAssistantID, conversationID: conversationID
            )
        )
        XCTAssertNil(result.error, "重试失败也必须通过事件表达")

        guard case .turnFailed = result.events.last else {
            return XCTFail("末事件应为 turnFailed，实际：\(String(describing: result.events.last))")
        }
        let fetchedNew = try await database.dbQueue.read { db in
            try MessageGroup.order(Column("turn_index").desc).fetchOne(db)
        }
        let newGroup = try XCTUnwrap(fetchedNew, "重试必须创建新组")
        XCTAssertNotEqual(newGroup.id, oldGroup.id)
        XCTAssertEqual(newGroup.status, .failed, "新组必须正确终结")
        XCTAssertNotNil(newGroup.closedAt)
        let newRows = try await groupRows(in: newGroup.id)
        XCTAssertEqual(newRows[1].status, .failed)
        XCTAssertEqual(newRows[1].text, "半截")

        let oldAfter = try await onlyGroup()
        XCTAssertEqual(oldAfter.status, .failed)
        let oldRowsFinal = try await groupRows(in: oldGroup.id)
        XCTAssertEqual(oldRowsFinal[1].id, oldAssistantID, "旧组不受影响")
    }

    // MARK: - G7 opening 阶段取消（尚未收到任何增量）

    func testG7_CancelInOpeningAbortsGroupWithoutRecoveryPending() async throws {
        let token = UUID()
        let gate = Gate()
        let gated = GatedGroupRepository(base: groups, gate: gate)
        let orchestrator = makeOrchestrator(
            provider: GatedProvider(firstChunk: "不应出现"),
            pageToken: token,
            groupsRepo: gated
        )
        let stream = orchestrator.send(text: "讲个故事", conversationID: conversationID)
        let recorder = EventRecorder()
        let collector = Task { await Self.consume(stream, into: recorder) }

        // openTurn 已进入但尚未提交，此时取消 → 落点为 opening 分支
        await gate.waitForEntry()
        await orchestrator.cancelActiveTurn(owner: token)
        gate.release()
        await collector.value

        let events = recorder.all
        XCTAssertNil(recorder.failure, "turnOpened 之前的基础设施错误才允许 throw")

        // ① 未收到任何增量 → partialText 为空
        let hasDelta = events.contains { if case .assistantDelta = $0 { return true }; return false }
        XCTAssertFalse(hasDelta, "opening 阶段不得产生任何增量事件")

        // ② 恰好一个终态，且必须是 turnCancelled
        let terminals = events.filter(isTerminal)
        XCTAssertEqual(terminals.count, 1, "必须恰好一个终态，实际事件：\(events)")
        guard case .turnCancelled = terminals.last else {
            return XCTFail("终态必须为 turnCancelled，实际：\(String(describing: terminals.last))")
        }

        // ③ 取消事务成功时不得再发 turnRecoveryPending
        let recoveryPending = events.contains { if case .turnRecoveryPending = $0 { return true }; return false }
        XCTAssertFalse(recoveryPending, "取消事务成功后不得发 turnRecoveryPending")

        // ④ 库状态：组 aborted、assistant canceled、无 sent_at、正文为空
        let group = try await onlyGroup()
        XCTAssertEqual(group.status, .aborted)
        XCTAssertNotNil(group.closedAt)
        let rows = try await groupRows(in: group.id)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].status, .canceled)
        XCTAssertNil(rows[1].sentAt, "取消不得写 sent_at")
        XCTAssertEqual(rows[1].text, "", "opening 阶段取消不保留正文（生产行为保持不变）")
    }

    // MARK: - P2-A 定向正文更新的四种结果（真实 SQLite）

    func testP2A_TargetedTextUpdateDistinguishesOutcomes() async throws {
        let opened = try await openGroupWithAssistant()

        // ① updated：只改 text，其余字段保持 sending / 无 sent_at
        let updated = try await messages.updateAssistantText("半截正文", for: opened.assistantID)
        XCTAssertEqual(updated, .updated)
        var row = try await groupRows(in: opened.group.id)[1]
        XCTAssertEqual(row.text, "半截正文")
        XCTAssertEqual(row.status, .sending)
        XCTAssertNil(row.sentAt)
        XCTAssertNil(row.replyToID, "定向更新不得触碰 reply_to_id")

        // ② 记录不存在
        let notFound = try await messages.updateAssistantText("x", for: "no-such-message")
        XCTAssertEqual(notFound, .notFound)
        let countAfter = try await database.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? 0
        }
        XCTAssertEqual(countAfter, 2, "notFound 不得新增行")

        // ③ 已终结 → statusMismatch，且正文与 sent_at 都不被覆盖
        try await turns.finalizeTurn(
            FinalizeTurnRequest(
                groupID: opened.group.id,
                assistantMessageID: opened.assistantID,
                text: "定稿正文",
                assistantStatus: .sent,
                sentAt: 8800,
                replyToID: nil,
                references: [],
                groupStatus: .complete,
                closedAt: 8800
            )
        )
        let mismatch = try await messages.updateAssistantText("取消时的半截", for: opened.assistantID)
        XCTAssertEqual(mismatch, .statusMismatch)
        row = try await groupRows(in: opened.group.id)[1]
        XCTAssertEqual(row.text, "定稿正文", "已终结正文不得被覆盖")
        XCTAssertEqual(row.status, .sent)
        XCTAssertEqual(row.sentAt, 8800)

        // ④ 软删（仍为 sending）→ 写入被拒，映射为 statusMismatch
        let soft = try await openGroupWithAssistant(turnIndex: 2, assistantText: "")
        try await database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE messages SET deleted_at = 999 WHERE id = ?",
                arguments: [soft.assistantID]
            )
        }
        let softResult = try await messages.updateAssistantText("不该写入", for: soft.assistantID)
        XCTAssertEqual(softResult, .statusMismatch)
        let softRow = try await messages.message(id: soft.assistantID)
        XCTAssertEqual(softRow?.text, "", "软删行不得被写入")
    }

    // MARK: - 竞争辅助

    private func openGroupWithAssistant() async throws -> (group: MessageGroup, assistantID: String) {
        try await openGroupWithAssistant(turnIndex: 1, assistantText: "半截")
    }

    private func openGroupWithAssistant(
        turnIndex: Int,
        assistantText: String
    ) async throws -> (group: MessageGroup, assistantID: String) {
        let group = MessageGroup(conversationID: conversationID, turnIndex: turnIndex)
        let user = Message(
            conversationID: conversationID, role: .user, text: "问题",
            status: .sent, origin: .user
        )
        let assistant = Message(
            conversationID: conversationID, role: .assistant, text: assistantText,
            status: .sending, origin: .reply
        )
        let opened = try await groups.openTurn(
            OpenTurnRequest(group: group, userMessage: user, assistantMessage: assistant)
        )
        return (opened, opened.assistantMessageID ?? assistant.id)
    }

    private static func attemptFinalize(
        _ request: FinalizeTurnRequest,
        barrier: AsyncBarrier,
        repo: GRDBMessageTurnRepository
    ) async -> Bool {
        await barrier.wait()
        do {
            try await repo.finalizeTurn(request)
            return true
        } catch {
            return false
        }
    }

    private static func attemptCancel(
        groupID: String,
        assistantMessageID: String,
        barrier: AsyncBarrier,
        repo: GRDBMessageGroupRepository
    ) async -> Bool {
        await barrier.wait()
        do {
            try await repo.cancelTurn(
                groupID: groupID,
                assistantMessageID: assistantMessageID,
                closedAt: 9100
            )
            return true
        } catch {
            return false
        }
    }
}

// MARK: - 测试替身

/// 线程安全的事件记录器：支持"等到首个信号"的确定性同步点。
/// 明确区分三种情况，避免"流提前结束"被误当作"已进入 streaming"。
enum FirstSignal: Sendable, Equatable {
    case delta
    case ended
    case failed(String)
}

final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [OrchestratorEvent] = []
    private var failureStorage: Error?
    private var firstSignal: FirstSignal?
    private var waiters: [CheckedContinuation<FirstSignal, Never>] = []

    var all: [OrchestratorEvent] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    var failure: Error? {
        lock.lock(); defer { lock.unlock() }
        return failureStorage
    }

    func append(_ event: OrchestratorEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
        if case .assistantDelta = event { resolve(.delta) }
    }

    func finish(error: Error?) {
        lock.lock()
        failureStorage = error
        lock.unlock()
        resolve(error.map { .failed(String(describing: $0)) } ?? .ended)
    }

    /// 等待首个信号：`.delta` 才算真正进入 streaming；`.ended` / `.failed` 必须由调用方判失败。
    func waitForDeltaOrEnd() async -> FirstSignal {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let firstSignal {
                lock.unlock()
                continuation.resume(returning: firstSignal)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func resolve(_ signal: FirstSignal) {
        lock.lock()
        guard firstSignal == nil else {
            lock.unlock()
            return
        }
        firstSignal = signal
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume(returning: signal) }
    }
}

/// 可控 Provider：吐出首段后阻塞，直到测试放行；用于"已进入 streaming"的确定性时点。
final class GatedProvider: ChatModelProvider, @unchecked Sendable {
    var identifier: String { "gated" }
    var capabilities: ModelCapabilities { [.text] }

    private let firstChunk: String
    private let sent = AsyncStreamSignal()
    private let releaseSignal = AsyncStreamSignal()

    init(firstChunk: String) { self.firstChunk = firstChunk }

    func waitUntilFirstChunkSent() async { await sent.wait() }
    func release() { releaseSignal.signal() }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.text(firstChunk))
                sent.signal()
                await releaseSignal.wait()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// 让定向正文更新失败的 MessageRepository 装饰器（其余方法原样委托）。
struct FailingMessageRepository: MessageRepository {
    let base: GRDBMessageRepository
    let failTextUpdate: Bool

    func insert(_ message: Message) async throws { try await base.insert(message) }

    func update(_ message: Message) async throws { try await base.update(message) }

    func message(id: String) async throws -> Message? { try await base.message(id: id) }

    func recentMessages(in conversationID: String, limit: Int) async throws -> [Message] {
        try await base.recentMessages(in: conversationID, limit: limit)
    }

    func count(in conversationID: String) async throws -> Int {
        try await base.count(in: conversationID)
    }

    func page(in conversationID: String, before: PageCursor?, limit: Int) async throws -> MessagePage {
        try await base.page(in: conversationID, before: before, limit: limit)
    }

    func messages(inGroup groupID: String) async throws -> [Message] {
        try await base.messages(inGroup: groupID)
    }

    func updateAssistantText(
        _ text: String,
        for messageID: String,
        expectedStatus: MessageStatus
    ) async throws -> AssistantTextUpdateResult {
        if failTextUpdate { throw DFError.database("模拟正文保存失败") }
        return try await base.updateAssistantText(
            text, for: messageID, expectedStatus: expectedStatus
        )
    }
}

/// 让 cancelTurn 失败的 MessageGroupRepository 装饰器。
struct FailingCancelGroupRepository: MessageGroupRepository {
    let base: GRDBMessageGroupRepository

    func openTurn(_ request: OpenTurnRequest) async throws -> MessageGroup {
        try await base.openTurn(request)
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
        throw DFError.database("模拟取消失败")
    }
    func repairStaleSending(in conversationID: String) async throws -> Int {
        try await base.repairStaleSending(in: conversationID)
    }
}

/// 门控定稿仓储：`finalizeTurn` 前阻塞，用于确定性制造"定稿进行中收到取消"。
final class FinalizeGate: @unchecked Sendable {
    let entry = AsyncStreamSignal()
    let releaseSignal = AsyncStreamSignal()

    func waitForEntry() async { await entry.wait() }
    func release() { releaseSignal.signal() }
    func holdAtEntry() async {
        entry.signal()
        await releaseSignal.wait()
    }
}

struct BlockingFinalizeTurnRepository: MessageTurnRepository {
    let base: GRDBMessageTurnRepository
    let gate: FinalizeGate

    func finalizeTurn(_ request: FinalizeTurnRequest) async throws {
        await gate.holdAtEntry()
        try await base.finalizeTurn(request)
    }

    func failTurn(groupID: String, assistantMessageID: String, text: String?, closedAt: Int64) async throws {
        try await base.failTurn(
            groupID: groupID, assistantMessageID: assistantMessageID, text: text, closedAt: closedAt
        )
    }
}

/// 双方会合后才同时放行的异步栅栏（不使用 sleep，也不依赖顺序）。
final class AsyncBarrier: @unchecked Sendable {
    private let parties: Int
    private let lock = NSLock()
    private var arrived = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(parties: Int) { self.parties = parties }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            arrived += 1
            if arrived == parties {
                let pending = waiters
                waiters.removeAll()
                lock.unlock()
                pending.forEach { $0.resume() }
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

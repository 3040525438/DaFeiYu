import XCTest
import Foundation
import GRDB
import DFCore
@testable import DFData
import DFOrchestration

/// B1-S4-A 测试：编排器启动恢复入口与恢复屏障（S4A-1 ~ S4A-5）。
///
/// 全部使用真实 `AppDatabase` + 真实迁移 + 真实仓储；
/// 只有 Provider、门控装饰器与信号工具是测试替身。
/// 竞争一律用信号/门控同步，**不使用 sleep**。
final class ChatOrchestratorRecoveryTests: XCTestCase {
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
            .appendingPathComponent("OrchRecovery-\(UUID().uuidString)", isDirectory: true)
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
        recoveryRepo: (any StaleTurnRecoveryRepository)?,
        groupsRepo: (any MessageGroupRepository)? = nil,
        messagesRepo: (any MessageRepository)? = nil,
        barrierProbe: (any RecoveryBarrierProbing)? = nil
    ) -> ChatOrchestratorImpl {
        let groupDependency: any MessageGroupRepository = groupsRepo ?? groups
        let messageDependency: any MessageRepository = messagesRepo ?? messages
        var deps = ChatOrchestratorDependencies(
            groups: groupDependency,
            turns: turns,
            messages: messageDependency,
            references: references,
            units: units,
            recovery: recoveryRepo,
            makeProvider: { provider },
            makeRequest: { system, history in
                ChatRequest(model: "fake-model", systemPrompt: system, messages: history)
            }
        )
        deps.barrierProbe = barrierProbe
        return ChatOrchestratorImpl(dependencies: deps)
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

    /// 构造"进程被杀"现场：open 组 + user 已 sent + assistant 仍 sending 且有半截正文
    @discardableResult
    private func seedStaleTurn(text: String = "半截回复") async throws -> (groupID: String, assistantID: String) {
        let now = Clock.nowMillis()
        let group = MessageGroup(conversationID: conversationID, turnIndex: 1, openedAt: now)
        let user = Message(
            conversationID: conversationID, role: .user, text: "你好",
            status: .sent, origin: .user, createdAt: now, sentAt: now
        )
        let assistant = Message(
            conversationID: conversationID, role: .assistant, text: "",
            status: .sending, origin: .reply, createdAt: now + 1
        )
        let opened = try await groups.openTurn(
            OpenTurnRequest(group: group, userMessage: user, assistantMessage: assistant)
        )
        let assistantID = opened.assistantMessageID ?? assistant.id
        _ = try await messages.updateAssistantText(text, for: assistantID)
        return (opened.id, assistantID)
    }

    private func groupCount() async throws -> Int {
        try await database.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM message_groups") ?? 0
        }
    }

    private func latestGroup() async throws -> MessageGroup {
        let fetched = try await database.dbQueue.read { db in
            try MessageGroup.order(Column("turn_index").desc).fetchOne(db)
        }
        return try XCTUnwrap(fetched, "数据库中没有任何消息组")
    }

    private func messageStatus(_ id: String) async throws -> MessageStatus? {
        try await messages.message(id: id)?.status
    }

    // MARK: - S4A-1 恢复修复 open 组与 sending 消息，并保留正文

    func testS4A_1_RecoverRepairsOpenGroupAndSendingMessage() async throws {
        let seeded = try await seedStaleTurn(text: "半截回复")

        let orchestrator = makeOrchestrator(provider: StaticProvider(deltas: [.text("未使用")]), recoveryRepo: groups)
        let report = try await orchestrator.recoverStaleTurns(conversationID: conversationID)

        XCTAssertEqual(report.repairedMessages, 1, "应有 1 条 sending 消息被修复")
        XCTAssertEqual(report.closedGroups, 1, "应关闭 1 个 open 组")
        XCTAssertNil(report.skippedActiveGroup, "无活跃轮次时不应跳过任何组")
        XCTAssertTrue(report.failures.isEmpty, "成功路径不应有失败诊断：\(report.failures)")

        let group = try await groups.group(id: seeded.groupID)
        XCTAssertEqual(group?.status, .failed)
        XCTAssertNotNil(group?.closedAt, "关闭必须补 closed_at")

        let assistant = try await messages.message(id: seeded.assistantID)
        XCTAssertEqual(assistant?.status, .failed)
        XCTAssertEqual(assistant?.text, "半截回复", "已生成正文必须保留，不得清空")
        XCTAssertNil(assistant?.sentAt, "不得把不完整回复标成已发送")
    }

    // MARK: - S4A-2 活跃轮次不被恢复误伤

    func testS4A_2_RecoverSkipsActiveTurn() async throws {
        let gate = Latch()
        let started = Latch()
        let provider = BlockingProvider(gate: gate, started: started)
        let orchestrator = makeOrchestrator(provider: provider, recoveryRepo: groups)

        let stream = orchestrator.send(text: "在吗", conversationID: conversationID)
        let consumer = Task { await Self.collect(stream) }

        await started.wait()  // 已进入 streaming：组已提交、assistant 为 sending

        let report = try await orchestrator.recoverStaleTurns(conversationID: conversationID)
        let activeGroupID = try XCTUnwrap(report.skippedActiveGroup, "有活跃轮次时必须报告被跳过的组")
        XCTAssertEqual(report.repairedMessages, 0, "活跃轮次的消息不得被修复")
        XCTAssertEqual(report.closedGroups, 0, "活跃轮次的组不得被关闭")

        let group = try await groups.group(id: activeGroupID)
        XCTAssertEqual(group?.status, .open, "活跃组必须保持 open")
        let inGroup = try await messages.messages(inGroup: activeGroupID)
        XCTAssertEqual(inGroup.first(where: { $0.role == .assistant })?.status, .sending, "生成中的 assistant 必须保持 sending")

        gate.signal()
        let result = await consumer.value
        XCTAssertNil(result.error)
        XCTAssertTrue(
            result.events.contains { if case .turnCompleted = $0 { return true } else { return false } },
            "释放后本轮应正常完成，实际事件：\(result.events)"
        )
    }

    // MARK: - S4A-3 幂等：第二次不重复写入

    func testS4A_3_RecoverIsIdempotent() async throws {
        try await seedStaleTurn()
        let orchestrator = makeOrchestrator(provider: StaticProvider(deltas: [.text("未使用")]), recoveryRepo: groups)

        let first = try await orchestrator.recoverStaleTurns(conversationID: conversationID)
        XCTAssertEqual(first.repairedMessages, 1)

        let second = try await orchestrator.recoverStaleTurns(conversationID: conversationID)
        XCTAssertEqual(second.repairedMessages, 0, "第二次恢复不得重复写入")
        XCTAssertEqual(second.closedGroups, 0)

        let closed = try await database.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM message_groups WHERE status = 'failed'") ?? 0
        }
        XCTAssertEqual(closed, 1)
    }

    // MARK: - S4A-4 恢复屏障：新轮次必须等恢复结束才 openTurn

    func testS4A_4_NewTurnWaitsForRecoveryBarrier() async throws {
        // ① 先造一轮完整历史，作为"重试"这一新轮次的合法目标（重试必然新建组）
        let seed = makeOrchestrator(
            provider: StaticProvider(deltas: [.text("旧回复")]),
            recoveryRepo: nil
        )
        let seeded = await Self.collect(seed.send(text: "旧提问", conversationID: conversationID))
        XCTAssertNil(seeded.error, "播种轮次必须成功：\(String(describing: seeded.error))")
        let baselineGroups = try await groupCount()
        XCTAssertEqual(baselineGroups, 1, "播种后应恰好存在一个组")

        let seededGroup = try await latestGroup()
        let seededRows = try await messages.messages(inGroup: seededGroup.id)
        let targetRow = try XCTUnwrap(
            seededRows.first { $0.role == .assistant },
            "播种轮次必须有 assistant 消息"
        )

        // ② 三段确定性同步（全部是信号/门控，无固定次数 yield、无 sleep、无时间轮询）：
        //    started        —— 恢复已真正进入恢复操作，屏障此刻已生效
        //    lookupEntered  —— 新轮次已在屏障之前运行，并被测试替身停驻（确定停驻点）
        //    lookupProceed  —— 放行停驻点，使新轮次走向屏障
        //    release        —— Gate：允许恢复完成
        let started = Latch()
        let release = Latch()
        let lookupEntered = Latch()
        let lookupProceed = Latch()
        let progressed = Latch()   // 屏障报告 waiting，或（屏障缺失时）轮次已越过屏障
        let milestones = RecoveryMilestones()
        let log = BarrierEventLog()

        // 断言失败时也要放行，避免遗留挂起任务
        defer {
            lookupProceed.signal()
            release.signal()
        }

        let gatedRecovery = GatedRecovery(base: groups, started: started, release: release)
        let orchestrator = makeOrchestrator(
            provider: StaticProvider(deltas: [.text("新回复")]),
            recoveryRepo: gatedRecovery,
            groupsRepo: ProbeGroupRepository(
                base: groups, milestones: milestones, log: log, progressed: progressed
            ),
            messagesRepo: ParkingMessageRepository(
                base: messages, lookupEntered: lookupEntered, proceed: lookupProceed
            ),
            barrierProbe: BarrierProbeRecorder(log: log, progressed: progressed)
        )

        let cid = conversationID!
        let recovery = Task { try await orchestrator.recoverStaleTurns(conversationID: cid) }
        await started.wait()   // 恢复已开始、屏障已生效，此后才允许检查新轮次

        // 新轮次（重试）：`run` 中第一处异步依赖就是屏障之前的取源文本，
        // 恰好给我们一个屏障之前的确定性停驻点。
        let consumer = Task {
            await Self.collect(orchestrator.retry(messageID: targetRow.id, conversationID: cid))
        }
        await lookupEntered.wait()   // 新轮次确定已在屏障之前运行，且被停住

        // 确定性断言：轮次停驻在 openTurn 之前，恢复未结束时不可能已有新组
        let duringRecovery = try await groupCount()
        XCTAssertEqual(duringRecovery, baselineGroups, "恢复屏障未释放前不得创建消息组")

        lookupProceed.signal()   // 放行停驻点 → 新轮次走向恢复屏障
        // 确定性推进点：正常由探针的 .waiting 唤醒；若屏障被删除，则由越过屏障后的
        // 首次依赖调用唤醒 —— 两种情况都不会挂起，后者会在下方断言中失败。
        await progressed.wait()
        milestones.markReleased()
        log.record(.releaseMarked)
        release.signal()         // Gate 释放 → 恢复真实落库并释放屏障

        let report = try await recovery.value
        XCTAssertEqual(report.repairedMessages, 0, "恢复期间不得把新轮次的消息当成陈旧消息修复")
        XCTAssertEqual(report.closedGroups, 0, "恢复期间不得关闭任何组")
        XCTAssertNil(report.skippedActiveGroup, "新轮次尚未建组，不应报告被跳过的活跃组")

        let result = await consumer.value
        XCTAssertNil(result.error)
        XCTAssertTrue(
            result.events.contains { if case .turnCompleted = $0 { return true } else { return false } },
            "屏障释放后新轮次应正常完成，实际事件：\(result.events)"
        )
        let afterRecovery = try await groupCount()
        XCTAssertEqual(afterRecovery, baselineGroups + 1, "只应新增一轮新组")
        XCTAssertFalse(
            milestones.createdBeforeRelease,
            "新轮次不得在恢复结束前越过屏障创建消息组"
        )

        // ---- 屏障回归证明：全部使用客观序号，在流程结束后求值（删除屏障时是失败而非挂起）----
        XCTAssertEqual(log.count(of: .reached), 1, "新轮次必须抵达恢复屏障调用点")
        XCTAssertEqual(
            log.count(of: .waiting), 1,
            "屏障必须真正进入等待分支（recoveryState == .running 且等待者已登记）"
        )

        let releaseSeq = try XCTUnwrap(log.seq(of: .releaseMarked), "缺少 release 标记")
        let resumedSeq = try XCTUnwrap(
            log.seq(of: .resumed), "屏障未记录 resumed：屏障可能被删除或失效"
        )
        let openTurnSeq = try XCTUnwrap(log.seq(of: .openTurn), "新轮次没有建组")
        XCTAssertGreaterThan(resumedSeq, releaseSeq, "越过屏障必须发生在恢复释放之后")
        XCTAssertGreaterThan(openTurnSeq, resumedSeq, "建组必须发生在越过屏障之后")

        XCTAssertEqual(
            log.entries.map(\.milestone).filter { $0 != .releaseMarked },
            [.reached, .waiting, .resumed, .openTurn],
            "事件顺序必须严格为 reached → waiting → resumed → openTurn，实际：\(log.entries)"
        )
    }

    // MARK: - S4A-5 恢复失败：如实上报且屏障仍释放

    func testS4A_5_RecoveryFailureSurfacesAndReleasesBarrier() async throws {
        let orchestrator = makeOrchestrator(
            provider: StaticProvider(deltas: [.text("好的")]),
            recoveryRepo: FailingRecovery()
        )

        do {
            _ = try await orchestrator.recoverStaleTurns(conversationID: conversationID)
            XCTFail("恢复失败必须抛错，不得伪造成功")
        } catch {
            let diagnostic = await orchestrator.lastDiagnostic
            XCTAssertNotNil(diagnostic, "恢复失败必须留下诊断")
            XCTAssertTrue(diagnostic?.contains("recovery_failed") == true, "诊断应标明是系统恢复失败：\(diagnostic ?? "nil")")
        }

        // 屏障已释放：新轮次不受阻塞，能正常开组并完成
        let result = await Self.collect(orchestrator.send(text: "恢复后再发", conversationID: conversationID))
        XCTAssertNil(result.error)
        XCTAssertTrue(
            result.events.contains { if case .turnCompleted = $0 { return true } else { return false } },
            "恢复失败后新轮次仍应可发送，实际事件：\(result.events)"
        )
    }
}

// MARK: - 测试替身

/// 一次性信号（可重复 signal，只唤醒一次）。
///
/// 支持多个等待者与取消唤醒，避免"漏唤醒 / 重复 resume / 永久等待"：
/// - 每个等待者以 UUID 登记，`signal()` 与 `onCancel` 都通过同一个加锁移除动作取走 continuation，
///   因此同一个 continuation 绝不会被 resume 两次；
/// - 已经 `signal` 之后到来的等待者立即返回，不会挂起。
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var signaled = false

    func signal() {
        lock.lock()
        guard !signaled else { lock.unlock(); return }
        signaled = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in pending.values { continuation.resume() }
    }

    func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if signaled {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters[id] = continuation
                lock.unlock()
            }
        } onCancel: {
            self.resumeWaiter(id)
        }
    }

    private func resumeWaiter(_ id: UUID) {
        lock.lock()
        let continuation = waiters.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume()
    }
}

/// 记录"消息组被创建时恢复是否已经释放"。
///
/// `@unchecked Sendable` 依据：全部可变状态由 `NSLock` 保护，且只做布尔标记。
private final class RecoveryMilestones: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var created = false

    func markReleased() {
        lock.lock()
        released = true
        lock.unlock()
    }

    /// 在 `openTurn` 处调用：若此刻尚未释放，说明新轮次越过了屏障。
    func markGroupCreated() {
        lock.lock()
        if !released { created = true }
        lock.unlock()
    }

    var createdBeforeRelease: Bool {
        lock.lock()
        defer { lock.unlock() }
        return created
    }
}

/// 屏障回归证明涉及的事件类型（客观事实，不含任何预期值）。
private enum BarrierMilestone: Sendable, Equatable {
    case reached
    case waiting
    case releaseMarked
    case resumed
    case openTurn
}

/// 统一事件日志：为屏障相关事件分配客观、单调递增的序号。
///
/// `@unchecked Sendable` 依据：全部可变状态由 `NSLock` 保护；
/// `record` 是同步纯内存操作（不挂起、不做 I/O），序号在同一把锁内自增，因此全局唯一且与调用顺序一致。
private final class BarrierEventLog: @unchecked Sendable {
    struct Entry: Sendable, Equatable {
        let seq: Int
        let milestone: BarrierMilestone
    }

    private let lock = NSLock()
    private var storage: [Entry] = []

    func record(_ milestone: BarrierMilestone) {
        lock.lock()
        storage.append(Entry(seq: storage.count + 1, milestone: milestone))
        lock.unlock()
    }

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func count(of milestone: BarrierMilestone) -> Int {
        entries.filter { $0.milestone == milestone }.count
    }

    func seq(of milestone: BarrierMilestone) -> Int? {
        entries.first { $0.milestone == milestone }?.seq
    }
}

/// 屏障探针实现：只写事件日志，不做任何阻塞或 I/O。
///
/// `progressed` 的作用：让测试有一个"确定可推进"的唤醒源。
/// 正常情况由 `.waiting` 唤醒；若屏障被删除，则由 `ProbeGroupRepository` 的
/// 越过屏障后的首次调用唤醒——测试因此**失败而不是挂起**。
private struct BarrierProbeRecorder: RecoveryBarrierProbing {
    let log: BarrierEventLog
    let progressed: Latch

    func record(_ event: RecoveryBarrierEvent) {
        switch event {
        case .reached:
            log.record(.reached)
        case .waiting:
            log.record(.waiting)
            progressed.signal()
        case .resumed:
            log.record(.resumed)
        }
    }
}

/// 组仓储探针：只观测 `openTurn` / `openGroup`，行为完全转发。
private struct ProbeGroupRepository: MessageGroupRepository {
    let base: any MessageGroupRepository
    let milestones: RecoveryMilestones
    let log: BarrierEventLog
    /// 见 `BarrierProbeRecorder.progressed`：屏障缺失时由此唤醒测试，避免挂起
    let progressed: Latch

    func openTurn(_ request: OpenTurnRequest) async throws -> MessageGroup {
        log.record(.openTurn)
        milestones.markGroupCreated()
        progressed.signal()
        return try await base.openTurn(request)
    }

    func group(id: String) async throws -> MessageGroup? {
        try await base.group(id: id)
    }

    func openGroup(in conversationID: String) async throws -> MessageGroup? {
        let existing = try await base.openGroup(in: conversationID)
        // 屏障之后的第一次依赖调用：屏障若失效，这里会先于 waiting 到达
        progressed.signal()
        return existing
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
        try await base.cancelTurn(
            groupID: groupID, assistantMessageID: assistantMessageID, closedAt: closedAt
        )
    }

    @discardableResult
    func repairStaleSending(in conversationID: String) async throws -> Int {
        try await base.repairStaleSending(in: conversationID)
    }
}

/// 消息仓储门控：`message(id:)` 是重试轮次在恢复屏障**之前**唯一会调用的异步依赖，
/// 在这里停驻即可得到"新轮次已开始运行、但尚未越过屏障"的确定性时点。
private struct ParkingMessageRepository: MessageRepository {
    let base: any MessageRepository
    let lookupEntered: Latch
    let proceed: Latch

    func message(id: String) async throws -> Message? {
        lookupEntered.signal()
        await proceed.wait()
        return try await base.message(id: id)
    }

    func insert(_ message: Message) async throws {
        try await base.insert(message)
    }

    func update(_ message: Message) async throws {
        try await base.update(message)
    }

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
        try await base.updateAssistantText(text, for: messageID, expectedStatus: expectedStatus)
    }
}

private struct StaticProvider: ChatModelProvider, @unchecked Sendable {
    var identifier: String { "static" }
    var capabilities: ModelCapabilities { [.text] }
    let deltas: [ChatDelta]

    init(deltas: [ChatDelta]) { self.deltas = deltas }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            for delta in deltas { continuation.yield(delta) }
            continuation.finish()
        }
    }
}

/// 首段增量后挂起，直到 `gate` 被放行（用于模拟"生成中"这一确定时点）。
private struct BlockingProvider: ChatModelProvider, @unchecked Sendable {
    var identifier: String { "blocking" }
    var capabilities: ModelCapabilities { [.text] }
    let gate: Latch
    let started: Latch

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text("第一段"))
            started.signal()
            Task {
                await gate.wait()
                continuation.finish()
            }
        }
    }
}

/// 门控恢复仓储：进入后立刻发出 `started`（此刻屏障已生效），
/// 随后挂起直到 Gate 放行才真正修复（制造"恢复持屏障"的确定时点）。
private struct GatedRecovery: StaleTurnRecoveryRepository, @unchecked Sendable {
    let base: GRDBMessageGroupRepository
    let started: Latch
    let release: Latch

    func repairStaleTurns(
        in conversationID: String,
        excludingGroupID: String?
    ) async throws -> StaleTurnRepairResult {
        started.signal()
        await release.wait()
        return try await base.repairStaleTurns(in: conversationID, excludingGroupID: excludingGroupID)
    }
}

private struct FailingRecovery: StaleTurnRecoveryRepository, @unchecked Sendable {
    func repairStaleTurns(
        in conversationID: String,
        excludingGroupID: String?
    ) async throws -> StaleTurnRepairResult {
        throw DFError.database("模拟恢复失败")
    }
}

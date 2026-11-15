import Foundation
import DFCore
import DFOrchestration

/// 协调器广播给页面的统一事件（L2）。
enum CoordinatorEvent: Sendable {
    /// 订阅/重连快照：页面据此恢复"本轮是否在生成、生成到哪一条、已累积多少文本"
    case snapshot(CoordinatorSnapshot)
    /// 编排器原始事件（顺序与编排器一致）
    case orchestrator(OrchestratorEvent)
    /// D49：本轮已暂停（模型流仍在缓冲，界面不再追加）
    case turnPaused(turnToken: UUID)
    /// D49：本轮已恢复（继续消费缓冲的增量）
    case turnResumed(turnToken: UUID)
    /// 本轮消费结束（含首个事件之前的失败）
    case turnEnded(turnToken: UUID, opened: Bool, error: String?)
}

/// 重新订阅快照。`turnToken == nil` 表示当前没有活跃轮次。
struct CoordinatorSnapshot: Sendable, Equatable {
    var turnToken: UUID?
    var groupID: String?
    var assistantMessageID: String?
    var accumulated: String
    /// D49：本轮是否处于暂停态（重新进入页面时据此复原按钮）
    var isPaused: Bool

    init(
        turnToken: UUID? = nil,
        groupID: String? = nil,
        assistantMessageID: String? = nil,
        accumulated: String = "",
        isPaused: Bool = false
    ) {
        self.turnToken = turnToken
        self.groupID = groupID
        self.assistantMessageID = assistantMessageID
        self.accumulated = accumulated
        self.isPaused = isPaused
    }

    static let idle = CoordinatorSnapshot()
}

/// 会话级生成协调器（L2 核心）。
///
/// 职责边界：
/// - **拥有**生成任务与编排器实例：任务生命周期脱离任何页面（Tab 切换 / 离开页面不中断）；
/// - **广播**编排器事件给所有订阅页面；
/// - **生成 turnToken**：页面 `stop()` 只能凭本轮 turnToken 取消，旧页面拿不到新 token；
/// - **登记/注销** `ActiveTurnRegistry`，供恢复路径排除活跃组。
///
/// 页面唯一职责：`subscribe` / `unsubscribe` / 渲染。页面不得直接触碰编排器。
@MainActor
final class ConversationCoordinator {
    let conversationID: String

    private let orchestrator: ChatOrchestratorImpl
    private let registry: ActiveTurnRegistry
    /// 编排器 owner token：容器级唯一，页面不可见，避免多页面共用同一 owner 语义
    private let ownerToken: UUID

    private var subscribers: [UUID: AsyncStream<CoordinatorEvent>.Continuation] = [:]
    private var consumeTask: Task<Void, Never>?
    /// D49 暂停闸门：暂停后消费循环挂起，不再向界面追加增量
    private let pauseGate = PauseGate()

    private(set) var turnToken: UUID?
    private(set) var groupID: String?
    private(set) var assistantMessageID: String?
    private(set) var accumulated = ""
    private(set) var isPaused = false

    init(
        conversationID: String,
        orchestrator: ChatOrchestratorImpl,
        ownerToken: UUID,
        registry: ActiveTurnRegistry
    ) {
        self.conversationID = conversationID
        self.orchestrator = orchestrator
        self.ownerToken = ownerToken
        self.registry = registry
    }

    /// 本会话是否正在生成（页面 onAppear 守卫、恢复排除的依据）
    var hasActiveTurn: Bool {
        consumeTask != nil
    }

    // MARK: - 订阅

    /// 订阅并**立即**投递一次快照（幂等，可重复调用）。
    func subscribe() -> (id: UUID, stream: AsyncStream<CoordinatorEvent>) {
        let id = UUID()
        var continuation: AsyncStream<CoordinatorEvent>.Continuation!
        let stream = AsyncStream<CoordinatorEvent> { continuation = $0 }
        subscribers[id] = continuation
        continuation.yield(.snapshot(snapshot()))
        return (id, stream)
    }

    /// 退订：只断开广播，**不**中断生成。
    func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)?.finish()
    }

    func snapshot() -> CoordinatorSnapshot {
        CoordinatorSnapshot(
            turnToken: turnToken,
            groupID: groupID,
            assistantMessageID: assistantMessageID,
            accumulated: accumulated,
            isPaused: isPaused
        )
    }

    // MARK: - 轮次启动

    /// 发起新一轮。返回 turnToken（页面持有用于停止）。
    func startSend(text: String) throws -> UUID {
        let orchestrator = self.orchestrator
        let conversationID = self.conversationID
        return try start {
            orchestrator.send(text: text, conversationID: conversationID)
        }
    }

    /// 重试（L2 仍沿用"新建组"契约，原位重试在 L5 实施）。
    func startRetry(messageID: String) throws -> UUID {
        let orchestrator = self.orchestrator
        let conversationID = self.conversationID
        return try start {
            orchestrator.retry(messageID: messageID, conversationID: conversationID)
        }
    }

    /// D49 续写：从某条 assistant 回复的断点继续写。
    func startContinue(messageID: String) throws -> UUID {
        let orchestrator = self.orchestrator
        let conversationID = self.conversationID
        return try start {
            orchestrator.continueTurn(messageID: messageID, conversationID: conversationID)
        }
    }

    private func start(
        _ makeStream: () -> AsyncThrowingStream<OrchestratorEvent, Error>
    ) throws -> UUID {
        guard consumeTask == nil else {
            throw ChatOrchestrationError.groupAlreadyOpen(groupID: groupID ?? "")
        }
        let token = UUID()
        turnToken = token
        groupID = nil
        assistantMessageID = nil
        accumulated = ""
        isPaused = false
        broadcast(.snapshot(snapshot()))

        let stream = makeStream()
        consumeTask = Task { [weak self] in
            await self?.consume(stream, token: token)
        }
        return token
    }

    /// 取消本轮。只有持有**当前** turnToken 的调用方生效（旧页面天然无效）。
    func cancelTurn(token: UUID) async {
        guard token == turnToken else { return }
        // 暂停中取消：先放行消费循环，否则它会一直挂在闸门上，轮次无法收尾
        await releasePauseIfNeeded()
        await orchestrator.cancelActiveTurn(owner: ownerToken)
    }

    // MARK: - 暂停 / 继续（D49）

    /// 暂停本轮：只挂起"界面消费"，不取消模型请求。
    ///
    /// 语义边界（如实说明，不夸大成"模型停止计算"）：
    /// - 已到达客户端的增量会被扣住，界面停止追加；
    /// - 网络流仍在服务端 / 客户端缓冲区里流动，恢复后从断点继续；
    /// - 长时间暂停会积压缓冲区，用户可选择"停止"彻底结束本轮。
    func pauseTurn(token: UUID) async {
        guard token == turnToken, consumeTask != nil, !isPaused else { return }
        isPaused = true
        await pauseGate.pause()
        broadcast(.turnPaused(turnToken: token))
        broadcast(.snapshot(snapshot()))
    }

    /// 恢复本轮：放行消费循环，继续追加增量。
    func resumeTurn(token: UUID) async {
        guard token == turnToken, consumeTask != nil, isPaused else { return }
        isPaused = false
        await pauseGate.resume()
        broadcast(.turnResumed(turnToken: token))
        broadcast(.snapshot(snapshot()))
    }

    private func releasePauseIfNeeded() async {
        guard isPaused else { return }
        isPaused = false
        await pauseGate.resume()
    }

    // MARK: - 恢复

    /// 启动恢复（包装编排器）。
    ///
    /// 全局活跃轮次保护：本会话有活跃轮次时**直接跳过**，绝不把在飞的组修成 failed。
    func recoverStaleTurns() async throws -> RecoveryReport {
        if let active = registry.activeGroupID(for: conversationID) {
            return RecoveryReport(
                skippedActiveGroup: active,
                failures: ["recovery: 会话存在活跃轮次，已跳过修复"]
            )
        }
        return try await orchestrator.recoverStaleTurns(conversationID: conversationID)
    }

    // MARK: - 消费与广播

    private func consume(
        _ stream: AsyncThrowingStream<OrchestratorEvent, Error>,
        token: UUID
    ) async {
        var opened = false
        var failure: String?

        do {
            for try await event in stream {
                // D49：暂停时挂在这里，既不丢事件也不向界面追加
                await pauseGate.waitIfPaused()
                if case .turnOpened = event { opened = true }
                apply(event)
                broadcast(.orchestrator(event))
            }
        } catch {
            failure = error.localizedDescription
        }

        if let gid = groupID {
            registry.end(conversationID: conversationID, groupID: gid)
        }
        turnToken = nil
        groupID = nil
        assistantMessageID = nil
        accumulated = ""
        isPaused = false
        consumeTask = nil
        broadcast(.turnEnded(turnToken: token, opened: opened, error: failure))
    }

    /// 只维护"当前轮次元信息"，不写库、不改变事件语义。
    private func apply(_ event: OrchestratorEvent) {
        switch event {
        case let .turnOpened(gid, _, aid):
            groupID = gid
            assistantMessageID = aid
            accumulated = ""
            registry.begin(conversationID: conversationID, groupID: gid)
        case let .assistantDelta(chunk):
            accumulated += chunk
        case let .assistantReplaced(text):
            accumulated = text
        case .assistantSegmented:
            // 多气泡已落库；快照累积文本以 assistantReplaced 为准，这里不改状态
            break
        case .turnCompleted, .turnFailed, .turnCancelled, .turnRecoveryPending:
            break
        }
    }

    private func broadcast(_ event: CoordinatorEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }
}

/// D49 暂停闸门。
///
/// 语义：`pause()` 之后所有 `waitIfPaused()` 调用会挂起，直到 `resume()`；
/// 状态只在内存，进程退出即消失，不存在"永久卡死"。
actor PauseGate {
    private var paused = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func pause() {
        paused = true
    }

    func resume() {
        paused = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func waitIfPaused() async {
        guard paused else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if paused {
                waiters.append(continuation)
            } else {
                continuation.resume()
            }
        }
    }
}

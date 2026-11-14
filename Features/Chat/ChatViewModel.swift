import Foundation
import Combine
import DFCore
import DFOrchestration

/// 聊天页视图模型。
///
/// 唯一发送链路：`orchestrator.send / retry` → `consume` → `apply`。
/// 本文件不再直接写任何消息（用户的、assistant 的都不写），落库全部由编排层事务完成。
///
/// 两套归属令牌分工（不得混用）：
/// - `pageToken`：编排器轮次的 owner（跨页面隔离，S1 契约）；
/// - `streamingTaskID`：本页 Task 的 UI 写入与清理资格（页内轮次隔离）。
@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [Message] = []
    @Published var draft: String = ""
    @Published private(set) var isStreaming = false
    @Published var errorText: String?
    @Published private(set) var hasModel: Bool = false

    /// 待恢复轮次（`turnRecoveryPending` 产生）：库里组仍为 `open`，属非终态。
    /// 仅保存编排器明确告知的 groupID，**绝不伪造**。
    @Published private(set) var pendingRecovery: PendingRecovery?

    struct PendingRecovery: Equatable, Sendable {
        var groupID: String
        var assistantMessageID: String
    }

    private let container: AppContainer
    private var conversationID: String = ""

    /// 编排器实例与 owner token：每个页面唯一，陈旧页面无法取消新轮次。
    private let orchestrator: ChatOrchestratorImpl
    private let pageToken: UUID

    /// 本轮 UI 状态（只有当前 Task 可改）
    private struct TurnState {
        var groupID: String
        var assistantMessageID: String
        var accumulated: String
    }
    private var currentTurn: TurnState?

    private var streamingTask: Task<Void, Never>?
    private var streamingTaskID: UUID?

    /// 本 VM 是否已成功完成一次启动恢复。失败不置位，允许下次 `onAppear` 重试。
    private var hasRecovered = false

    init(container: AppContainer) {
        self.container = container
        let token = UUID()
        self.pageToken = token
        self.orchestrator = ChatOrchestratorImpl(
            dependencies: container.makeOrchestratorDependencies(),
            pageToken: token
        )
    }

    // MARK: - 生命周期

    func onAppear() async {
        do {
            let conversation = try await container.conversations.ensureMainConversation(title: "大肥鱼")
            conversationID = conversation.id

            await recoverIfNeeded(conversationID: conversation.id)

            // S5-B 仍保持原有可见历史范围（300 条）；分页接口与分页 UI 延后到 S5-D
            messages = try await container.messages.recentMessages(in: conversation.id, limit: 300)
            hasModel = (try await container.modelConfigs.defaultConfig()) != nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// 页面离开：交出本页的 UI 写入资格，并取消编排器轮次。
    ///
    /// - 与 `stop()` 语义不同：这里连消费任务一起取消（页面已不可见，无需终态事件）；
    /// - 取消 Task 会经 `onTermination` 让编排器 `run` 走 `cancelPath`（detached 持久化保证事务仍能提交）。
    func onDisappear() {
        let token = pageToken
        let task = streamingTask

        // 立即剥夺旧任务的 UI 写入资格：其后续 recheck 都会失败
        streamingTaskID = nil
        streamingTask = nil
        isStreaming = false
        currentTurn = nil

        Task { await orchestrator.cancelActiveTurn(owner: token) }
        task?.cancel()
    }

    // MARK: - 用户操作

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        guard conversationID.isEmpty == false else {
            errorText = "会话还没准备好，请稍后再试"
            return
        }
        guard pendingRecovery == nil, !hasUnfinishedAssistant else {
            errorText = "上一轮还没收尾，正在等待恢复完成"
            return
        }
        // 未配置模型：必须在进入编排器之前拦下，否则事务 A 会先建组再失败（脏组）
        guard hasModel else {
            errorText = DFError.notConfigured("默认模型（请到设置页添加）").localizedDescription
            return
        }

        draft = ""
        start(
            stream: orchestrator.send(text: text, conversationID: conversationID)
        )
    }

    /// 重试：仅允许失败的 assistant 消息；创建**新组**，旧组/旧消息/旧引用保持不变。
    func retry(_ message: Message) {
        guard !isStreaming else { return }
        guard message.role == .assistant, message.status == .failed else { return }
        guard conversationID.isEmpty == false else { return }
        guard pendingRecovery == nil, !hasUnfinishedAssistant else {
            errorText = "上一轮还没收尾，正在等待恢复完成"
            return
        }
        guard hasModel else {
            errorText = DFError.notConfigured("默认模型（请到设置页添加）").localizedDescription
            return
        }
        start(
            stream: orchestrator.retry(messageID: message.id, conversationID: conversationID)
        )
    }

    /// 停止生成：只取消编排器轮次，**不取消消费任务**（否则拿不到 `turnCancelled`）。
    func stop() {
        guard isStreaming else { return }
        let token = pageToken
        Task { await orchestrator.cancelActiveTurn(owner: token) }
    }

    func delete(_ message: Message) {
        guard !isStreaming else { return }
        Task {
            await softDelete(message)
        }
    }

    /// 该消息是否处于"待恢复"（非终态）。冷启动无法得知 groupID，按 status 判定。
    func isPendingRecovery(_ message: Message) -> Bool {
        if let pending = pendingRecovery, pending.assistantMessageID == message.id { return true }
        return message.role == .assistant && message.status == .sending && !isStreaming
    }

    private var hasUnfinishedAssistant: Bool {
        messages.contains { $0.role == .assistant && $0.status == .sending }
    }

    // MARK: - 轮次启动与清理

    private func start(stream: AsyncThrowingStream<OrchestratorEvent, Error>) {
        let id = UUID()
        // 新一轮启动前清理上一轮的残留
        errorText = nil
        currentTurn = nil
        streamingTaskID = id
        isStreaming = true
        streamingTask = Task { [weak self] in
            await self?.consume(stream, taskID: id)
        }
    }

    /// 唯一清理段：之间**没有 await**，因此不会被其它 MainActor 任务插入。
    private func finishTurn(taskID: UUID) {
        guard streamingTaskID == taskID else { return }
        isStreaming = false
        streamingTask = nil
        streamingTaskID = nil
        currentTurn = nil
    }

    private func isCurrentTask(_ taskID: UUID) -> Bool {
        streamingTaskID == taskID && streamingTask != nil
    }

    // MARK: - 事件消费

    private enum EventOutcome {
        case other
        case terminal
        /// `turnRecoveryPending`：非终态，但本轮事件已结束
        case pending
    }

    private func consume(
        _ stream: AsyncThrowingStream<OrchestratorEvent, Error>,
        taskID: UUID
    ) async {
        var outcome: EventOutcome = .other
        do {
            for try await event in stream {
                guard isCurrentTask(taskID) else { return }
                outcome = await apply(event, taskID: taskID)
            }
        } catch {
            guard isCurrentTask(taskID) else { return }
            if outcome == .other {
                // 首事件之前抛错（零写入）或消费被取消：只报告错误，不伪造终态
                errorText = error.localizedDescription
            }
        }

        guard isCurrentTask(taskID) else { return }
        if outcome == .other, let turn = currentTurn {
            // 未收到任何终态：以库内真值为准重读一次；读到 sending 时保持"待恢复"，不伪造终态
            await reloadMessage(id: turn.assistantMessageID, taskID: taskID)
            guard isCurrentTask(taskID) else { return }
        }
        finishTurn(taskID: taskID)
    }

    private func apply(_ event: OrchestratorEvent, taskID: UUID) async -> EventOutcome {
        switch event {
        case let .turnOpened(groupID, userMessageID, assistantMessageID):
            let user = try? await container.messages.message(id: userMessageID)
            let assistant = try? await container.messages.message(id: assistantMessageID)
            guard isCurrentTask(taskID) else { return .other }

            if let user { upsert(user) }
            if let assistant { upsert(assistant) }
            currentTurn = TurnState(
                groupID: groupID,
                assistantMessageID: assistantMessageID,
                accumulated: assistant?.text ?? ""
            )
            // 与旧链路一致：每轮开始刷新会话时间（编排层不负责该字段）
            try? await container.conversations.touch(id: conversationID, at: Clock.nowMillis())
            return .other

        case let .assistantDelta(chunk):
            guard var turn = currentTurn else { return .other }
            turn.accumulated += chunk
            currentTurn = turn
            updateText(id: turn.assistantMessageID, text: turn.accumulated)
            return .other

        case let .assistantReplaced(text):
            guard var turn = currentTurn else { return .other }
            turn.accumulated = text
            currentTurn = turn
            updateText(id: turn.assistantMessageID, text: text)
            return .other

        case let .turnCompleted(_, assistantMessageID, _),
             let .turnFailed(_, assistantMessageID, _),
             let .turnCancelled(_, assistantMessageID):
            // 终态以库内真值为准：取消路径不保证发 assistantReplaced，
            // 正文必须重读数据库；状态也不得由本地猜测。
            await reloadMessage(id: assistantMessageID, taskID: taskID)
            guard isCurrentTask(taskID) else { return .terminal }
            pendingRecovery = nil
            return .terminal

        case let .turnRecoveryPending(groupID, assistantMessageID, reason):
            guard isCurrentTask(taskID) else { return .pending }
            // 非终态：保持消息真实 status（sending），只登记待恢复
            pendingRecovery = PendingRecovery(
                groupID: groupID,
                assistantMessageID: assistantMessageID
            )
            NSLog("本轮待恢复（group=\(groupID)）：\(reason)")
            return .pending
        }
    }

    // MARK: - 启动恢复

    /// 启动恢复（S4-A 屏障在编排器内部生效）。
    ///
    /// 守卫：
    /// 1. 有活跃消费任务 → 跳过（本页正在生成，恢复会误改在飞消息）；
    /// 2. 已成功恢复过且没有待恢复轮次 → 跳过；
    /// 3. 存在待恢复轮次 → 允许再试（复位 `hasRecovered`）；
    /// 4. 失败不置成功标志，下次 `onAppear` 可重试。
    private func recoverIfNeeded(conversationID: String) async {
        guard streamingTask == nil else { return }
        if pendingRecovery != nil { hasRecovered = false }
        guard !hasRecovered else { return }

        do {
            let report = try await orchestrator.recoverStaleTurns(conversationID: conversationID)
            hasRecovered = true

            if let pending = pendingRecovery {
                if let message = try? await container.messages.message(id: pending.assistantMessageID) {
                    upsert(message)
                    if message.status != .sending {
                        pendingRecovery = nil
                    } else {
                        // 仍为 sending：保留待恢复，明确告知用户
                        errorText = "上一轮仍未收尾，请重启应用后再试"
                    }
                } else {
                    pendingRecovery = nil
                }
            }

            if !report.failures.isEmpty {
                NSLog("启动恢复存在未完成项：\(report.failures.joined(separator: "；"))")
            }
        } catch {
            NSLog("启动恢复失败：\(error.localizedDescription)")
            errorText = error.localizedDescription
        }
    }

    // MARK: - 消息装载

    private func reloadMessage(id: String, taskID: UUID) async {
        guard let message = try? await container.messages.message(id: id) else { return }
        guard isCurrentTask(taskID) else { return }
        upsert(message)
    }

    private func updateText(id: String, text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = text
    }

    private func upsert(_ message: Message) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }

    private func softDelete(_ message: Message) async {
        var copy = message
        copy.deletedAt = Clock.nowMillis()
        do {
            try await container.messages.update(copy)
            messages.removeAll { $0.id == message.id }
        } catch {
            errorText = error.localizedDescription
        }
    }
}

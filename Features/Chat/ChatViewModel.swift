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

    /// D2：本轮发送前的原始文本，仅用于"确认未发出"时恢复输入框。
    private var draftSnapshot: String?

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
            // D1：`hasRecovered` 只代表"历史上恢复过"，不代表"现在没有残留"。
            // 装载后仍有未完成的 assistant 时，再补一次恢复（每次页面出现最多一次）。
            await recoverStaleAfterLoad(conversationID: conversation.id)
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
        draftSnapshot = text          // D2：仅 send 有草稿可恢复；retry 不设
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
        draftSnapshot = nil           // D2：重试没有草稿，绝不恢复
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
        draftSnapshot = nil           // D2：兜底清理，避免快照残留到下一轮
    }

    private func isCurrentTask(_ taskID: UUID) -> Bool {
        streamingTaskID == taskID && streamingTask != nil
    }

    /// D2：仅当"本轮确实没有创建任何消息"且用户没有重新输入时，才把原文放回输入框。
    private func restoreDraftIfNeeded() {
        guard let snapshot = draftSnapshot else { return }
        draftSnapshot = nil
        guard draft.isEmpty else { return }        // 用户已重新输入 → 绝不覆盖
        draft = snapshot
        if errorText == nil {                      // 已有真实错误时保留错误文案
            errorText = "消息未发出，已恢复到输入框"
        }
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
        var didOpenTurn = false       // D2：本轮是否真的开了组（决定能否恢复草稿）
        do {
            for try await event in stream {
                guard isCurrentTask(taskID) else { return }
                outcome = await apply(event, taskID: taskID)
                // 所有权仍然有效时，才认定"本页确实收到了开组事件"
                if case .turnOpened = event, isCurrentTask(taskID) {
                    didOpenTurn = true
                }
            }
        } catch {
            guard isCurrentTask(taskID) else { return }
            if outcome == .other {
                // 首事件之前抛错（零写入）或消费被取消：只报告错误，不伪造终态
                errorText = error.localizedDescription
            }
        }

        guard isCurrentTask(taskID) else { return }
        if !didOpenTurn {
            // 整轮没有任何开组事件（preflight 取消 / 前置失败）→ 库里零写入，草稿可安全还原
            restoreDraftIfNeeded()
        }
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
             let .turnCancelled(_, assistantMessageID):
            // 终态以库内真值为准：取消路径不保证发 assistantReplaced，
            // 正文必须重读数据库；状态也不得由本地猜测。
            await reloadMessage(id: assistantMessageID, taskID: taskID)
            guard isCurrentTask(taskID) else { return .terminal }
            pendingRecovery = nil
            return .terminal

        case let .turnFailed(_, assistantMessageID, reason):
            // F1：失败原因必须先脱敏再截断，再分类成可行动文案。
            // 原始 reason 可能携带上游响应体，禁止直接上屏或原样写入日志。
            await reloadMessage(id: assistantMessageID, taskID: taskID)
            guard isCurrentTask(taskID) else { return .terminal }
            pendingRecovery = nil
            let safe = Self.sanitizedFailure(reason)
            errorText = Self.userFacingFailure(safe)
            NSLog("[chat] 轮次失败 assistant=\(assistantMessageID) reason=\(safe)")
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

    /// D1 补偿恢复：`hasRecovered` 只代表"历史上恢复过"，不代表"现在没有残留"。
    ///
    /// 触发条件（三者缺一不可）：
    /// 1. 本页没有活跃轮次（正常生成中不得误判为待恢复）；
    /// 2. 没有处于"待恢复"提示中（该状态需用户重启，恢复也修不掉）；
    /// 3. 装载后的快照里确实还有 `sending` 的 assistant。
    ///
    /// 每次页面出现最多执行一次；失败复位 `hasRecovered`，下次进入页面可再试。
    private func recoverStaleAfterLoad(conversationID: String) async {
        guard !isStreaming else { return }
        guard pendingRecovery == nil else { return }
        guard hasUnfinishedAssistant else { return }

        do {
            _ = try await orchestrator.recoverStaleTurns(conversationID: conversationID)
            hasRecovered = true
            messages = try await container.messages.recentMessages(in: conversationID, limit: 300)
            NSLog("装载后补偿恢复完成")
        } catch {
            hasRecovered = false
            NSLog("装载后补偿恢复失败：\(error.localizedDescription)")
        }
    }

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

    // MARK: - 失败原因（F1）

    /// 失败原因脱敏。
    ///
    /// `reason` 可能来自上游响应体，必须先去掉凭据形态的片段，再截断。
    /// 顺序固定：**先脱敏、后截断**，避免截断把密钥切一半导致正则失效。
    private static func sanitizedFailure(_ text: String) -> String {
        var result = text
        let rules: [(pattern: String, replacement: String)] = [
            (#"(?i)bearer\s+\S+"#, "Bearer ***"),
            (#"sk-[A-Za-z0-9_\-]{8,}"#, "sk-***"),
            (#"(?i)api[_-]?key["'\s:=]+\S{4,}"#, "api_key=***")
        ]
        for rule in rules {
            result = result.replacingOccurrences(
                of: rule.pattern,
                with: rule.replacement,
                options: .regularExpression
            )
        }
        return String(result.prefix(200))
    }

    /// 把（已脱敏的）失败原因映射为可行动的用户文案。
    ///
    /// 判定依据是 `DFError.errorDescription` 的真实文案结构，不做模糊猜测：
    /// - 编排器内部令牌：`empty_reply` / `persistence`
    /// - `DFError.http`：`服务返回 <status>：<body>`
    /// - 其余为固定前缀。
    private static func userFacingFailure(_ safe: String) -> String {
        switch true {
        case safe == "empty_reply":
            return "模型没有返回内容，请点按重发"
        case safe == "persistence":
            return "本地保存失败，请重启应用后重试"
        case safe.contains("服务返回 401"), safe.contains("服务返回 403"):
            return "密钥无效或无权限，请到设置检查"
        case safe.contains("服务返回 429"):
            return "请求过于频繁或额度不足，请稍后重试"
        case safe.contains("服务返回 5"):
            return "模型服务暂时不可用，请稍后重试"
        case safe.contains("网络错误"):
            return "网络连接失败，请检查网络后重发"
        case safe.contains("数据解析失败"):
            return "返回内容无法解析，请重发"
        case safe.contains("尚未配置"):
            return safe
        default:
            return "生成失败，请稍后重试"
        }
    }
}

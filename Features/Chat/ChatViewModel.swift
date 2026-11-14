import Foundation
import Combine
import DFCore

/// 聊天页视图模型。
///
/// L2 起职责收窄：**只订阅、渲染、退订**。
/// 生成任务的所有权在容器级 `ConversationCoordinator`（按 `conversationID` 唯一），
/// 因此切换 Tab、离开页面都不会中断正在进行的轮次。
///
/// 两套归属令牌分工（不得混用）：
/// - `currentTurnToken`：协调器发放的轮次令牌，页面只能凭它停止**当前**轮次；
/// - `subscriptionID`：本页订阅的资格，退订后旧回调一律失效。
@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [Message] = []
    @Published var draft: String = ""
    @Published private(set) var isStreaming = false
    @Published var errorText: String?
    @Published private(set) var hasModel: Bool = false

    /// W2-7：外观设置（主题/背景/气泡/字号/头像），默认值兜底
    @Published private(set) var theme: ChatTheme = .default
    /// W2-5：会话内搜索
    @Published var searchQuery: String = ""
    @Published private(set) var searchHits: [ChatSearchHit] = []
    /// 搜索定位：命中的消息 id，由列表滚动后清空
    @Published var scrollTargetID: String?
    /// W2-3：编辑态
    @Published var editingMessage: Message?
    @Published var editDraft: String = ""

    // MARK: - W3 多会话

    /// 未归档会话（含置顶排序），顺序由数据层统一决定
    @Published private(set) var conversations: [ConversationSummary] = []
    /// 已归档会话（仍可进入、可检索）
    @Published private(set) var archivedConversations: [ConversationSummary] = []
    /// 全部会话未读总数
    @Published private(set) var unreadTotal: Int = 0

    /// 待恢复轮次（`turnRecoveryPending` 产生）：库里组仍为 `open`，属非终态。
    /// 仅保存编排器明确告知的 groupID，**绝不伪造**。
    @Published private(set) var pendingRecovery: PendingRecovery?

    struct PendingRecovery: Equatable, Sendable {
        var groupID: String
        var assistantMessageID: String
    }

    private let container: AppContainer
    private var conversationID: String = ""

    /// 会话协调器（容器持有，页面只是引用；页面生命周期不影响生成）
    private var coordinator: ConversationCoordinator?
    private var subscriptionID: UUID?
    private var subscriptionTask: Task<Void, Never>?

    /// 本轮 UI 状态（只有当前订阅可改）
    private struct TurnState {
        var groupID: String
        var assistantMessageID: String
        var accumulated: String
    }
    private var currentTurn: TurnState?

    /// 本轮令牌：来自协调器（`startSend/startRetry` 返回值或订阅快照）
    private var currentTurnToken: UUID?

    /// 本轮事件的终态类型，决定收尾时是否需要以库内真值重读
    private enum EventOutcome {
        case other
        case terminal
        /// `turnRecoveryPending`：非终态，但本轮事件已结束
        case pending
    }
    private var lastOutcome: EventOutcome = .other

    /// 本 VM 是否已成功完成一次启动恢复。失败不置位，允许下次 `onAppear` 重试。
    private var hasRecovered = false

    /// D2：本轮发送前的原始文本，仅用于"确认未发出"时恢复输入框。
    private var draftSnapshot: String?

    init(container: AppContainer) {
        self.container = container
    }

    // MARK: - 生命周期

    func onAppear() async {
        do {
            let conversation = try await container.conversations.ensureMainConversation(title: "大肥鱼")
            // 已切换过会话时保留当前会话，避免每次回到页面都被拉回主会话
            let target = conversationID.isEmpty ? conversation.id : conversationID
            try await activate(conversationID: target)
            hasModel = (try await container.modelConfigs.defaultConfig()) != nil
            theme = (try? await container.chatTheme.load()) ?? .default
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// 激活会话：退订旧会话 → 重置会话级状态 → 装载历史 → 订阅 → 补偿恢复 → 标已读 → 刷新列表。
    ///
    /// 只在该会话**没有活跃轮次**时被调用（生成中禁止切换）。
    private func activate(conversationID id: String) async throws {
        unsubscribeCurrent()
        conversationID = id
        let coordinator = container.conversationCoordinator(for: id)
        self.coordinator = coordinator

        hasRecovered = false
        pendingRecovery = nil
        currentTurn = nil
        currentTurnToken = nil
        lastOutcome = .other
        isStreaming = false
        scrollTargetID = nil
        draftSnapshot = nil
        clearSearch()
        cancelEdit()

        await recoverIfNeeded(coordinator: coordinator)

        // 与 V1 一致：首屏只显示最近 300 条，更早的历史靠分页
        messages = try await container.messages.recentMessages(in: id, limit: 300)

        subscribe(coordinator)
        // 快照优先：正在生成的那条文本以协调器内存为准（库内可能尚为空或滞后）
        applySnapshot(coordinator.snapshot())

        await recoverStaleAfterLoad(coordinator: coordinator)

        // 进入会话即视为已读；随后刷新列表让未读徽标同步
        try? await container.conversationAdmin.markRead(id: id, at: Clock.nowMillis())
        await refreshConversationList()
    }

    /// 页面离开：只退订，**不取消生成**（任务所有权在协调器）。
    ///
    /// 不重置 `isStreaming`：回到页面时由订阅快照纠正真实状态。
    func onDisappear() {
        unsubscribeCurrent()
        currentTurn = nil
    }

    // MARK: - 用户操作

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        guard let coordinator else {
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
        do {
            currentTurnToken = try coordinator.startSend(text: text)
        } catch {
            // 未开轮（协调器已有活跃轮次）：零写入，恢复输入框
            errorText = error.localizedDescription
            draftSnapshot = nil
            draft = text
            return
        }
        beginLocalTurn()
    }

    /// 重试：仅允许失败的 assistant 消息；L2 仍为"新建组"，原位重试在 L5 实施。
    func retry(_ message: Message) {
        guard !isStreaming else { return }
        guard message.role == .assistant, message.status == .failed else { return }
        guard let coordinator else { return }
        guard pendingRecovery == nil, !hasUnfinishedAssistant else {
            errorText = "上一轮还没收尾，正在等待恢复完成"
            return
        }
        guard hasModel else {
            errorText = DFError.notConfigured("默认模型（请到设置页添加）").localizedDescription
            return
        }
        draftSnapshot = nil           // D2：重试没有草稿，绝不恢复
        do {
            currentTurnToken = try coordinator.startRetry(messageID: message.id)
        } catch {
            errorText = error.localizedDescription
            return
        }
        beginLocalTurn()
    }

    /// 停止生成：只凭本轮令牌请求取消，不触碰订阅（否则拿不到终态事件）。
    func stop() {
        guard isStreaming, let coordinator, let token = currentTurnToken else { return }
        Task { await coordinator.cancelTurn(token: token) }
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

    /// 供"清空会话"使用：当前会话 id
    var conversationIDForDeletion: String { conversationID }

    // MARK: - W2 消息交互（编辑 / 撤回 / 收藏 / 删除 / 搜索 / 外观）

    func beginEdit(_ message: Message) {
        guard !isStreaming, message.deletedAt == nil, message.revokedAt == nil else { return }
        editingMessage = message
        editDraft = message.text
    }

    func cancelEdit() {
        editingMessage = nil
        editDraft = ""
    }

    func commitEdit() async {
        guard let target = editingMessage else { return }
        do {
            let outcome = try await container.editing.editMessage(
                id: target.id,
                newText: editDraft,
                editedAt: Clock.nowMillis()
            )
            editingMessage = nil
            editDraft = ""
            if !outcome.changed {
                errorText = "内容没有变化"
            }
            await reloadMessage(id: target.id)
        } catch {
            errorText = Self.interactionMessage(error)
        }
    }

    func revoke(_ message: Message) async {
        do {
            try await container.editing.revokeMessage(
                id: message.id,
                reason: nil,
                revokedAt: Clock.nowMillis()
            )
            await reloadMessage(id: message.id)
        } catch {
            errorText = Self.interactionMessage(error)
        }
    }

    func toggleFavorite(_ message: Message) async {
        do {
            try await container.editing.setFavorite(
                id: message.id,
                isFavorite: !message.isFavorite,
                at: Clock.nowMillis()
            )
            await reloadMessage(id: message.id)
        } catch {
            errorText = Self.interactionMessage(error)
        }
    }

    /// 批量删除入口（逐条 / 按日期 / 按关键词 / 清空会话）
    func delete(_ scope: MessageDeleteScope) async {
        guard !isStreaming else { return }
        do {
            _ = try await container.deletion.softDelete(
                scope,
                in: conversationID,
                at: Clock.nowMillis()
            )
            messages = try await container.messages.recentMessages(in: conversationID, limit: 300)
        } catch {
            errorText = Self.interactionMessage(error)
        }
    }

    func runSearch() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchHits = []
            return
        }
        do {
            searchHits = try await container.chatSearch.search(
                query: query,
                conversationID: conversationID,
                limit: 50
            )
        } catch {
            errorText = Self.interactionMessage(error)
        }
    }

    func clearSearch() {
        searchQuery = ""
        searchHits = []
    }

    /// 定位命中消息：不在当前窗口时先重新装载最近 300 条，再交给列表滚动
    func revealSearchHit(_ hit: ChatSearchHit) async {
        if !messages.contains(where: { $0.id == hit.messageID }) {
            messages = (try? await container.messages.recentMessages(in: conversationID, limit: 300)) ?? messages
        }
        guard messages.contains(where: { $0.id == hit.messageID }) else {
            errorText = "这条消息不在最近 300 条内，请先加载更早的消息"
            return
        }
        scrollTargetID = hit.messageID
        searchHits = []
        searchQuery = ""
    }

    func saveTheme(_ theme: ChatTheme) async {
        do {
            try await container.chatTheme.save(theme)
            self.theme = theme.normalized()
        } catch {
            errorText = Self.interactionMessage(error)
        }
    }

    func resetTheme() async {
        do {
            theme = try await container.chatTheme.reset()
        } catch {
            errorText = Self.interactionMessage(error)
        }
    }

    private static func interactionMessage(_ error: Error) -> String {
        if let interaction = error as? MessageInteractionError { return interaction.description }
        if let admin = error as? ConversationAdminError { return admin.description }
        return error.localizedDescription
    }

    // MARK: - W3 多会话操作

    /// 当前会话 id（供列表高亮）
    var activeConversationID: String { conversationID }

    /// 从数据层重载会话列表与未读总数
    func refreshConversationList() async {
        conversations = (try? await container.conversationAdmin.list(.active)) ?? conversations
        archivedConversations = (try? await container.conversationAdmin.list(.archived)) ?? archivedConversations
        unreadTotal = (try? await container.conversationAdmin.unreadTotal()) ?? unreadTotal
    }

    /// 切换会话。生成中禁止切换，避免把"另一个会话的轮次"绑到当前视图。
    func switchConversation(to id: String) async {
        guard id != conversationID else { return }
        guard !isStreaming else {
            errorText = "正在生成中，请先停止或等待完成再切换会话"
            return
        }
        do {
            try await activate(conversationID: id)
            draft = ""
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// 手动新建会话并立即进入
    func createConversation(title: String) async {
        guard !isStreaming else {
            errorText = "正在生成中，请先停止或等待完成再新建会话"
            return
        }
        do {
            let created = try await container.conversationAdmin.create(
                title: title,
                kind: "chat",
                at: Clock.nowMillis()
            )
            try await activate(conversationID: created.id)
            draft = ""
        } catch {
            errorText = Self.interactionMessage(error)
        }
    }

    func renameConversation(id: String, title: String) async {
        do {
            try await container.conversationAdmin.rename(id: id, title: title)
            await refreshConversationList()
        } catch {
            errorText = Self.interactionMessage(error)
        }
    }

    func togglePin(_ summary: ConversationSummary) async {
        do {
            try await container.conversationAdmin.setPinned(
                id: summary.id,
                pinned: !summary.isPinned,
                at: Clock.nowMillis()
            )
            await refreshConversationList()
        } catch {
            errorText = Self.interactionMessage(error)
        }
    }

    func toggleArchive(_ summary: ConversationSummary) async {
        do {
            try await container.conversationAdmin.setArchived(
                id: summary.id,
                archived: !summary.isArchived,
                at: Clock.nowMillis()
            )
            await refreshConversationList()
            // 当前会话被归档：列表里已隐藏，但页面仍停留在该会话，不强行跳走
        } catch {
            errorText = Self.interactionMessage(error)
        }
    }

    /// 删除会话（只删消息，不删记忆）。删除当前会话时自动回到主会话。
    func deleteConversations(ids: [String]) async {
        guard !isStreaming else {
            errorText = "正在生成中，请先停止或等待完成再删除会话"
            return
        }
        do {
            let result = try await container.conversationAdmin.deleteBatch(ids: ids)
            if result.skippedProtected > 0 {
                errorText = "主会话不可删除，已跳过"
            }
            if ids.contains(conversationID) {
                let main = try await container.conversations.ensureMainConversation(title: "大肥鱼")
                try await activate(conversationID: main.id)
                draft = ""
            } else {
                await refreshConversationList()
            }
        } catch {
            errorText = Self.interactionMessage(error)
        }
    }

    func markAllConversationsRead() async {
        _ = try? await container.conversationAdmin.markAllRead(at: Clock.nowMillis())
        await refreshConversationList()
    }

    // MARK: - 订阅

    private func subscribe(_ coordinator: ConversationCoordinator) {
        unsubscribeCurrent()
        let (id, stream) = coordinator.subscribe()
        subscriptionID = id
        subscriptionTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                if Task.isCancelled { return }
                await self.handle(event, subscriptionID: id)
            }
        }
    }

    private func unsubscribeCurrent() {
        if let id = subscriptionID {
            coordinator?.unsubscribe(id)
        }
        subscriptionTask?.cancel()
        subscriptionID = nil
        subscriptionTask = nil
    }

    // MARK: - 轮次状态

    private func beginLocalTurn() {
        errorText = nil
        currentTurn = nil
        lastOutcome = .other
        isStreaming = true
    }

    /// 清理段：之间**没有 await**，不会被其它 MainActor 任务插入。
    private func finishTurn(token: UUID, opened: Bool, error: String?) async {
        guard token == currentTurnToken else { return }

        // 整轮没有任何开组事件（preflight 取消 / 前置失败）→ 库里零写入，草稿可安全还原
        if !opened {
            restoreDraftIfNeeded()
        }
        if let error, errorText == nil {
            errorText = error
        }
        if lastOutcome == .other, let turn = currentTurn,
           let message = try? await container.messages.message(id: turn.assistantMessageID) {
            // 未收到任何终态：以库内真值为准重读一次；仍为 sending 时保持"待恢复"
            upsert(message)
        }

        guard token == currentTurnToken else { return }
        isStreaming = false
        currentTurn = nil
        currentTurnToken = nil
        draftSnapshot = nil           // D2：兜底清理，避免快照残留到下一轮
        lastOutcome = .other
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

    // MARK: - 事件处理

    private func handle(_ event: CoordinatorEvent, subscriptionID: UUID) async {
        guard subscriptionID == self.subscriptionID else { return }
        switch event {
        case let .snapshot(snapshot):
            applySnapshot(snapshot)
        case let .orchestrator(orchestratorEvent):
            await apply(orchestratorEvent, subscriptionID: subscriptionID)
        case let .turnEnded(token, opened, error):
            await finishTurn(token: token, opened: opened, error: error)
        }
    }

    /// 订阅/重连快照：恢复"本轮是否在生成、生成到哪一条、已累积多少文本"。
    /// 幂等，重复投递不产生副作用。
    private func applySnapshot(_ snapshot: CoordinatorSnapshot) {
        guard let token = snapshot.turnToken else {
            currentTurnToken = nil
            currentTurn = nil
            isStreaming = false
            return
        }
        currentTurnToken = token
        isStreaming = true
        guard let assistantMessageID = snapshot.assistantMessageID else {
            // 已开轮但 `turnOpened` 尚未投递：稍后由事件补齐
            currentTurn = nil
            return
        }
        currentTurn = TurnState(
            groupID: snapshot.groupID ?? "",
            assistantMessageID: assistantMessageID,
            accumulated: snapshot.accumulated
        )
        if messages.contains(where: { $0.id == assistantMessageID }) {
            updateText(id: assistantMessageID, text: snapshot.accumulated)
        }
    }

    private func apply(_ event: OrchestratorEvent, subscriptionID: UUID) async {
        switch event {
        case let .turnOpened(groupID, userMessageID, assistantMessageID):
            let user = try? await container.messages.message(id: userMessageID)
            let assistant = try? await container.messages.message(id: assistantMessageID)
            guard subscriptionID == self.subscriptionID else { return }

            if let user { upsert(user) }
            if let assistant { upsert(assistant) }
            currentTurn = TurnState(
                groupID: groupID,
                assistantMessageID: assistantMessageID,
                accumulated: assistant?.text ?? ""
            )
            // 与旧链路一致：每轮开始刷新会话时间（编排层不负责该字段）
            try? await container.conversations.touch(id: conversationID, at: Clock.nowMillis())
            return

        case let .assistantDelta(chunk):
            guard var turn = currentTurn else { return }
            turn.accumulated += chunk
            currentTurn = turn
            updateText(id: turn.assistantMessageID, text: turn.accumulated)
            return

        case let .assistantReplaced(text):
            guard var turn = currentTurn else { return }
            turn.accumulated = text
            currentTurn = turn
            updateText(id: turn.assistantMessageID, text: text)
            return

        case let .assistantSegmented(groupID, _):
            // 多气泡：以库内真值刷新本轮所有气泡（每条有自己的 messageID 与状态）
            if let rows = try? await container.messages.messages(inGroup: groupID) {
                guard subscriptionID == self.subscriptionID else { return }
                for row in rows where row.deletedAt == nil {
                    upsert(row)
                }
            }
            return

        case let .turnCompleted(_, assistantMessageID, _),
             let .turnCancelled(_, assistantMessageID):
            // 终态以库内真值为准：取消路径不保证发 assistantReplaced，
            // 正文必须重读数据库；状态也不得由本地猜测。
            await reloadMessage(id: assistantMessageID, subscriptionID: subscriptionID)
            guard subscriptionID == self.subscriptionID else { return }
            pendingRecovery = nil
            lastOutcome = .terminal
            return

        case let .turnFailed(_, assistantMessageID, reason):
            // F1：失败原因必须先脱敏再截断，再分类成可行动文案。
            // 原始 reason 可能携带上游响应体，禁止直接上屏或原样写入日志。
            await reloadMessage(id: assistantMessageID, subscriptionID: subscriptionID)
            guard subscriptionID == self.subscriptionID else { return }
            pendingRecovery = nil
            lastOutcome = .terminal
            let safe = Self.sanitizedFailure(reason)
            errorText = Self.userFacingFailure(safe)
            NSLog("[chat] 轮次失败 assistant=\(assistantMessageID) reason=\(safe)")
            return

        case let .turnRecoveryPending(groupID, assistantMessageID, reason):
            guard subscriptionID == self.subscriptionID else { return }
            // 非终态：保持消息真实 status（sending），只登记待恢复
            pendingRecovery = PendingRecovery(
                groupID: groupID,
                assistantMessageID: assistantMessageID
            )
            lastOutcome = .pending
            NSLog("本轮待恢复（group=\(groupID)）：\(reason)")
            return
        }
    }

    // MARK: - 启动恢复

    /// 启动恢复（S4-A 屏障在编排器内部生效）。
    ///
    /// 守卫：
    /// 1. 协调器有活跃轮次 → 跳过（L2：在飞的组绝不能被恢复路径误改）；
    /// 2. 已成功恢复过且没有待恢复轮次 → 跳过；
    /// 3. 存在待恢复轮次 → 允许再试（复位 `hasRecovered`）；
    /// 4. 失败不置成功标志，下次 `onAppear` 可重试。
    private func recoverIfNeeded(coordinator: ConversationCoordinator) async {
        guard !coordinator.hasActiveTurn else { return }
        if pendingRecovery != nil { hasRecovered = false }
        guard !hasRecovered else { return }

        do {
            let report = try await coordinator.recoverStaleTurns()
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
    /// 1. 协调器没有活跃轮次（L2：生成中不得误判为待恢复）；
    /// 2. 没有处于"待恢复"提示中（该状态需用户重启，恢复也修不掉）；
    /// 3. 装载后的快照里确实还有 `sending` 的 assistant。
    ///
    /// 每次页面出现最多执行一次；失败复位 `hasRecovered`，下次进入页面可再试。
    private func recoverStaleAfterLoad(coordinator: ConversationCoordinator) async {
        guard !coordinator.hasActiveTurn else { return }
        guard pendingRecovery == nil else { return }
        guard hasUnfinishedAssistant else { return }

        do {
            _ = try await coordinator.recoverStaleTurns()
            hasRecovered = true
            messages = try await container.messages.recentMessages(in: conversationID, limit: 300)
            NSLog("装载后补偿恢复完成")
        } catch {
            hasRecovered = false
            NSLog("装载后补偿恢复失败：\(error.localizedDescription)")
        }
    }

    /// 交互操作后的单条重读（无订阅约束：编辑/撤回/收藏由本页直接发起）
    private func reloadMessage(id: String) async {
        guard let message = try? await container.messages.message(id: id) else { return }
        upsert(message)
    }

    private func reloadMessage(id: String, subscriptionID: UUID) async {
        guard let message = try? await container.messages.message(id: id) else { return }
        guard subscriptionID == self.subscriptionID else { return }
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

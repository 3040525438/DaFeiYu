import Foundation
import DFCore
import DFData

/// 编排器依赖集合。全部以协议注入，`DFOrchestration` 因此不需要依赖 `DFAI`。
public struct ChatOrchestratorDependencies: Sendable {
    public var groups: any MessageGroupRepository
    public var turns: any MessageTurnRepository
    public var messages: any MessageRepository
    public var references: any MessageReferenceRepository
    public var units: any ContextUnitProviding
    /// 每次开新轮次时构造 Provider（由 App 层按当前设置决定，闭包注入）
    public var makeProvider: @Sendable () async throws -> any ChatModelProvider
    /// 用 system prompt 与历史构造请求（模型 id / 温度等参数由 App 层提供）
    public var makeRequest: @Sendable (_ systemPrompt: String, _ history: [ChatTurn]) async throws -> ChatRequest
    /// 核心人格（为空时使用空字符串，不影响流程）
    public var corePersona: @Sendable () async throws -> String
    public var rules: String
    public var limitGroups: Int
    public var budget: PromptBudget

    public init(
        groups: any MessageGroupRepository,
        turns: any MessageTurnRepository,
        messages: any MessageRepository,
        references: any MessageReferenceRepository,
        units: any ContextUnitProviding,
        makeProvider: @escaping @Sendable () async throws -> any ChatModelProvider,
        makeRequest: @escaping @Sendable (String, [ChatTurn]) async throws -> ChatRequest,
        corePersona: @escaping @Sendable () async throws -> String = { "" },
        rules: String = PromptComposer.defaultRules,
        limitGroups: Int = 20,
        budget: PromptBudget = PromptBudget()
    ) {
        self.groups = groups
        self.turns = turns
        self.messages = messages
        self.references = references
        self.units = units
        self.makeProvider = makeProvider
        self.makeRequest = makeRequest
        self.corePersona = corePersona
        self.rules = rules
        self.limitGroups = limitGroups
        self.budget = budget
    }
}

/// `ChatOrchestrator` 的唯一生产实现。
///
/// 事务边界（与 A2 仓储一一对应）：
/// - 事务 A：`MessageGroupRepository.openTurn`
/// - 事务 B：`MessageTurnRepository.finalizeTurn`（引用在其中写入，**不再**调 `insertBatch`）
/// - 事务 C：`MessageTurnRepository.failTurn` / `MessageGroupRepository.cancelTurn`
///
/// 状态机（r3）：
/// `idle → opening → streaming → closing → idle`；
/// `cancelActiveTurn(owner:)` 只在 owner 匹配且处于 opening/streaming 时生效，
/// 重复调用与终态阶段调用均为 no-op（0 写入）。
public actor ChatOrchestratorImpl: ChatOrchestrator {

    private enum Phase: Sendable, Equatable {
        case idle
        case opening(groupID: String?, assistantMessageID: String?)
        case streaming(groupID: String, assistantMessageID: String)
        case closing(groupID: String, assistantMessageID: String)
    }

    private let deps: ChatOrchestratorDependencies
    /// 页面归属 token：只有持同一 token 的调用方才能取消本轮次
    private let pageToken: UUID
    private let observerBox = ObserverBox()

    private var phase: Phase = .idle
    private var cancelRequested = false
    /// 最近一次非终态失败的可诊断信息（正文保存失败、补偿失败等）。
    /// 不进入事件契约，仅供日志与测试断言"错误未被静默吞掉"。
    public private(set) var lastDiagnostic: String?
    /// 当前轮次 Task（用于取消；由 `makeStream` 同步写入，避免 actor 重入竞态）
    private let taskBox = TaskBox()

    public init(dependencies: ChatOrchestratorDependencies, pageToken: UUID = UUID()) {
        self.deps = dependencies
        self.pageToken = pageToken
    }

    // MARK: - ChatOrchestrator

    public nonisolated var observer: ChatLifecycleObserver? {
        get { observerBox.value }
        set { observerBox.value = newValue }
    }

    public nonisolated func send(
        text: String,
        conversationID: String
    ) -> AsyncThrowingStream<OrchestratorEvent, Error> {
        makeStream(text: text, retryMessageID: nil, conversationID: conversationID)
    }

    public nonisolated func retry(
        messageID: String,
        conversationID: String
    ) -> AsyncThrowingStream<OrchestratorEvent, Error> {
        makeStream(text: nil, retryMessageID: messageID, conversationID: conversationID)
    }

    public func cancelActiveTurn(owner: UUID) async {
        // 归属校验：旧页面 / 旧 ViewModel / 错误 token 一律 no-op
        guard owner == pageToken else { return }

        switch phase {
        case .idle, .closing:
            return
        case .opening, .streaming:
            // 幂等：重复取消只重复置位，不会产生第二次状态转换
            cancelRequested = true
            taskBox.value?.cancel()
        }
    }

    // MARK: - 只读状态（测试与 UI 用）

    public var isTurnActive: Bool {
        if case .idle = phase { return false }
        return true
    }

    // MARK: - 流构建

    private nonisolated func makeStream(
        text: String?,
        retryMessageID: String?,
        conversationID: String
    ) -> AsyncThrowingStream<OrchestratorEvent, Error> {
        AsyncThrowingStream { continuation in
            // 必须强持有 self：`send` 返回后若调用方不保留编排器实例，
            // 弱引用会让已在进行的轮次**静默消失**（无事件、无错误、不建组）。
            // 生命周期由 `onTermination` 保证：消费方丢弃流时取消 Task，run 结束即释放。
            let task = Task {
                await self.run(
                    text: text,
                    retryMessageID: retryMessageID,
                    conversationID: conversationID,
                    continuation: continuation
                )
            }
            taskBox.set(task)
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 主流程

    private func run(
        text: String?,
        retryMessageID: String?,
        conversationID: String,
        continuation: AsyncThrowingStream<OrchestratorEvent, Error>.Continuation
    ) async {
        defer {
            phase = .idle
            cancelRequested = false
            taskBox.set(nil)
        }

        lastDiagnostic = nil

        // ---- 前置检查：全部在"首个事件之前"，失败允许 throw，且不产生任何新行 ----
        guard case .idle = phase else {
            let groupID: String
            switch phase {
            case .opening(let id, _):
                groupID = id ?? ""
            case .streaming(let id, _):
                groupID = id
            case .closing(let id, _):
                groupID = id
            case .idle:
                groupID = ""
            }
            continuation.finish(throwing: ChatOrchestrationError.groupAlreadyOpen(groupID: groupID))
            return
        }

        let trimmed: String
        if let retryMessageID {
            do {
                trimmed = try await retrySourceText(messageID: retryMessageID)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                continuation.finish(throwing: ChatOrchestrationError.assistantMessageMissing)
                return
            }
        } else {
            trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty else {
            continuation.finish(throwing: ChatOrchestrationError.emptyInput)
            return
        }

        // 库里已有 open 组：不允许并发开组（P1.5 恒 createNew）
        do {
            if let existing = try await deps.groups.openGroup(in: conversationID) {
                continuation.finish(throwing: ChatOrchestrationError.groupAlreadyOpen(groupID: existing.id))
                return
            }
        } catch {
            continuation.finish(throwing: ChatOrchestrationError.persistenceFailed(reason: describe(error)))
            return
        }

        // ---- 组装上下文与提示词 ----
        let composed: ContextComposer.Result
        do {
            let units = try await deps.units.recentUnits(
                conversationID: conversationID,
                limitGroups: deps.limitGroups
            )
            composed = ContextComposer.compose(units: units, budget: deps.budget)
        } catch {
            continuation.finish(throwing: ChatOrchestrationError.persistenceFailed(reason: describe(error)))
            return
        }

        let persona = (try? await deps.corePersona()) ?? ""
        let prompt = PromptComposer.compose(
            PromptInput(corePersona: persona, rules: deps.rules, history: composed.turns),
            budget: deps.budget
        )
        let systemPrompt = prompt.system + "\n\n" + ReferenceProtocol.systemFragment

        // 取消发生在 openTurn 之前：不得创建消息组（时序 A）
        if shouldStop() {
            continuation.finish()
            return
        }

        // ---- 事务 A：openTurn（成功后才允许请求模型）----
        let now = Clock.nowMillis()
        let group = MessageGroup(conversationID: conversationID, turnIndex: 1, openedAt: now)
        let userMessage = Message(
            conversationID: conversationID,
            role: .user,
            text: trimmed,
            status: .sent,
            origin: .user,
            createdAt: now,
            sentAt: now
        )
        let assistantMessage = Message(
            conversationID: conversationID,
            role: .assistant,
            text: "",
            status: .sending,
            origin: .reply,
            createdAt: now
        )

        phase = .opening(groupID: nil, assistantMessageID: nil)
        let opened: MessageGroup
        let openRepo = deps.groups
        do {
            // 事务 A 必须不受"生成 Task 被取消"的影响：取消可能恰好落在事务执行期间。
            opened = try await detachPersistence {
                try await openRepo.openTurn(
                    OpenTurnRequest(group: group, userMessage: userMessage, assistantMessage: assistantMessage)
                )
            }
        } catch {
            // 事务 A 失败：不发模型请求，库里不留新行
            continuation.finish(throwing: ChatOrchestrationError.persistenceFailed(reason: describe(error)))
            return
        }

        let groupID = opened.id
        let assistantID = opened.assistantMessageID ?? assistantMessage.id
        phase = .opening(groupID: groupID, assistantMessageID: assistantID)
        continuation.yield(
            .turnOpened(
                groupID: groupID,
                userMessageID: opened.userMessageID ?? userMessage.id,
                assistantMessageID: assistantID
            )
        )

        // opening 期间收到取消：组已提交，必须先终结它（r3 §6.3-①）
        if shouldStop() {
            await cancelPath(
                groupID: groupID,
                assistantMessageID: assistantID,
                partialText: nil,
                continuation: continuation
            )
            return
        }

        // ---- 模型请求 ----
        phase = .streaming(groupID: groupID, assistantMessageID: assistantID)
        var parser = StreamingReferenceParser()
        var visibleAccumulated = ""

        do {
            let provider = try await deps.makeProvider()
            let request = try await deps.makeRequest(systemPrompt, prompt.messages)
            if shouldStop() { throw CancellationError() }

            for try await delta in provider.stream(request) {
                if shouldStop() { throw CancellationError() }
                if case let .text(chunk) = delta {
                    let visible = parser.feed(chunk)
                    if !visible.isEmpty {
                        visibleAccumulated += visible
                        continuation.yield(.assistantDelta(visible))
                    }
                }
            }
        } catch {
            if shouldStop() || isCancellation(error) {
                await cancelPath(
                    groupID: groupID,
                    assistantMessageID: assistantID,
                    partialText: visibleAccumulated.isEmpty ? nil : visibleAccumulated,
                    continuation: continuation
                )
            } else {
                await failPath(
                    groupID: groupID,
                    assistantMessageID: assistantID,
                    text: visibleAccumulated.isEmpty ? nil : visibleAccumulated,
                    reason: describe(error),
                    continuation: continuation
                )
            }
            return
        }

        if shouldStop() {
            await cancelPath(
                groupID: groupID,
                assistantMessageID: assistantID,
                partialText: visibleAccumulated.isEmpty ? nil : visibleAccumulated,
                continuation: continuation
            )
            return
        }

        // ---- finish()：整段替换 ----
        let output = parser.finish()
        let finalText = output.visibleText
        guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await failPath(
                groupID: groupID,
                assistantMessageID: assistantID,
                text: nil,
                reason: "empty_reply",
                continuation: continuation
            )
            return
        }

        continuation.yield(.assistantReplaced(finalText))

        // ---- 事务 B：正文 + reply_to_id + 引用 + 组状态，一次原子提交 ----
        let kept = await validate(
            citations: output.citations,
            allowed: composed.allowedMessageIDs,
            conversationID: conversationID
        )
        let references = kept.enumerated().map { index, refID in
            MessageReference(
                messageID: assistantID,
                refMessageID: refID,
                relation: index == 0 ? .reply : .context
            )
        }

        phase = .closing(groupID: groupID, assistantMessageID: assistantID)
        do {
            try await deps.turns.finalizeTurn(
                FinalizeTurnRequest(
                    groupID: groupID,
                    assistantMessageID: assistantID,
                    text: finalText,
                    assistantStatus: .sent,
                    sentAt: Clock.nowMillis(),
                    replyToID: kept.first,
                    references: references,
                    groupStatus: .complete,
                    closedAt: Clock.nowMillis()
                )
            )
            continuation.yield(
                .turnCompleted(groupID: groupID, assistantMessageID: assistantID, citations: kept)
            )
            continuation.finish()
        } catch {
            // 事务 B 失败：走补偿；若组已被取消方终结则以库内真实状态为准
            await failPath(
                groupID: groupID,
                assistantMessageID: assistantID,
                text: finalText,
                reason: describe(error),
                continuation: continuation
            )
        }
    }

    // MARK: - 事务 C

    private func cancelPath(
        groupID: String,
        assistantMessageID: String,
        partialText: String?,
        continuation: AsyncThrowingStream<OrchestratorEvent, Error>.Continuation
    ) async {
        phase = .closing(groupID: groupID, assistantMessageID: assistantMessageID)

        // ① 先落已生成正文。失败**不得静默**：记录诊断，但继续走取消事务。
        //    用定向接口只改 text 一列，且仅在 sending 状态可写，避免覆盖已定稿内容。
        var textSaveError: String?
        if let partialText, !partialText.isEmpty {
            let messagesRepo = deps.messages
            do {
                let outcome = try await detachPersistence {
                    try await messagesRepo.updateAssistantText(
                        partialText,
                        for: assistantMessageID,
                        expectedStatus: .sending
                    )
                }
                switch outcome {
                case .updated:
                    break
                case .statusMismatch:
                    textSaveError = "assistant 已不在 sending，跳过正文回写"
                    lastDiagnostic = "正文保存跳过：" + (textSaveError ?? "")
                case .notFound:
                    textSaveError = "assistant 消息不存在"
                    lastDiagnostic = "正文保存跳过：" + (textSaveError ?? "")
                }
            } catch {
                textSaveError = describe(error)
                lastDiagnostic = "正文保存失败：" + describe(error)
            }
        }

        // ② 取消事务：成功才是唯一的 turnCancelled 来源。
        let groupsRepo = deps.groups
        do {
            try await detachPersistence {
                try await groupsRepo.cancelTurn(
                    groupID: groupID,
                    assistantMessageID: assistantMessageID,
                    closedAt: Clock.nowMillis()
                )
            }
            if let textSaveError {
                lastDiagnostic = "取消成功，但正文未完整保存：" + textSaveError
            }
            continuation.yield(
                .turnCancelled(groupID: groupID, assistantMessageID: assistantMessageID)
            )
        } catch {
            // ③ 失败：先回查真实终态；仍为 open 时**不得**伪造任何终态事件
            if let event = await terminalEventFromDB(
                groupID: groupID,
                assistantMessageID: assistantMessageID
            ) {
                continuation.yield(event)
            } else {
                let detail = [
                    "cancel_failed: " + describe(error),
                    textSaveError.map { "text_save_failed: " + $0 }
                ].compactMap { $0 }.joined(separator: " | ")
                lastDiagnostic = detail
                continuation.yield(
                    .turnRecoveryPending(
                        groupID: groupID,
                        assistantMessageID: assistantMessageID,
                        reason: detail
                    )
                )
            }
        }
        continuation.finish()
    }

    private func failPath(
        groupID: String,
        assistantMessageID: String,
        text: String?,
        reason: String,
        continuation: AsyncThrowingStream<OrchestratorEvent, Error>.Continuation
    ) async {
        phase = .closing(groupID: groupID, assistantMessageID: assistantMessageID)
        let turnsRepo = deps.turns
        do {
            try await detachPersistence {
                try await turnsRepo.failTurn(
                    groupID: groupID,
                    assistantMessageID: assistantMessageID,
                    text: text,
                    closedAt: Clock.nowMillis()
                )
            }
            continuation.yield(
                .turnFailed(groupID: groupID, assistantMessageID: assistantMessageID, reason: reason)
            )
        } catch {
            // 补偿失败：回查真实终态；仍为 open 时只能报告"待恢复"，不得伪造 failed
            if let event = await terminalEventFromDB(
                groupID: groupID,
                assistantMessageID: assistantMessageID
            ) {
                continuation.yield(event)
            } else {
                let detail = "fail_failed: " + reason + " | compensation: " + describe(error)
                lastDiagnostic = detail
                continuation.yield(
                    .turnRecoveryPending(
                        groupID: groupID,
                        assistantMessageID: assistantMessageID,
                        reason: detail
                    )
                )
            }
        }
        continuation.finish()
    }

    // MARK: - 辅助

    /// 持久化执行边界：不继承"生成 Task"的取消状态。
    ///
    /// `cancelActiveTurn` 取消的是生成 Task，而 GRDB 的 async 写入检测到取消会直接抛
    /// `CancellationError`，导致取消/失败补偿事务根本无法提交（组会永久停在 open）。
    /// 这里只隔离"必须完成"的持久化操作，并在原地 await 结果；
    /// 生成流程本身仍留在原 Task 内，取消对模型流仍然即时生效。
    private func detachPersistence<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: operation).value
    }

    private func terminalEventFromDB(
        groupID: String,
        assistantMessageID: String
    ) async -> OrchestratorEvent? {
        let groupsRepo = deps.groups
        let referencesRepo = deps.references
        guard let group = try? await detachPersistence({ try await groupsRepo.group(id: groupID) }) else {
            return nil
        }
        switch group.status {
        case .open:
            return nil
        case .complete:
            let refs = (try? await detachPersistence {
                try await referencesRepo.references(for: [assistantMessageID])
            }) ?? []
            return .turnCompleted(
                groupID: groupID,
                assistantMessageID: assistantMessageID,
                citations: refs.map(\.refMessageID)
            )
        case .failed:
            return .turnFailed(
                groupID: groupID,
                assistantMessageID: assistantMessageID,
                reason: "persistence"
            )
        case .aborted:
            return .turnCancelled(groupID: groupID, assistantMessageID: assistantMessageID)
        }
    }

    private func retrySourceText(messageID: String) async throws -> String {
        guard let target = try await deps.messages.message(id: messageID),
              target.role == .assistant else {
            throw ChatOrchestrationError.assistantMessageMissing
        }
        if let groupID = target.groupID {
            let rows = try await deps.messages.messages(inGroup: groupID)
            if let user = rows.first(where: { $0.role == .user }) {
                return user.text
            }
        }
        if let replyTo = target.replyToID, let source = try await deps.messages.message(id: replyTo) {
            return source.text
        }
        throw ChatOrchestrationError.assistantMessageMissing
    }

    private func validate(
        citations: [String],
        allowed: Set<String>,
        conversationID: String
    ) async -> [String] {
        guard !citations.isEmpty else { return [] }
        let found = (try? await deps.references.messages(ids: citations)) ?? []
        var existing: [String: String] = [:]
        var deleted: Set<String> = []
        for message in found {
            if message.deletedAt != nil {
                deleted.insert(message.id)
            } else {
                existing[message.id] = message.conversationID
            }
        }
        let result = ReferenceProtocol.validate(
            ReferenceProtocol.ValidationInput(
                citations: citations,
                allowed: allowed,
                existingConversationMap: existing,
                deletedIDs: deleted,
                conversationID: conversationID
            )
        )
        return result.kept
    }

    /// 是否应停止本轮：显式取消位、任务取消、或组已进入收尾
    private func shouldStop() -> Bool {
        if cancelRequested { return true }
        if Task.isCancelled { return true }
        if case .closing = phase { return true }
        return false
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let df = error as? DFError, df == .cancelled { return true }
        return false
    }

    private func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

/// `observer` 需要满足协议的 nonisolated `get set`，用引用盒子承接。
private final class ObserverBox: @unchecked Sendable {
    var value: ChatLifecycleObserver?
}

/// 轮次 Task 的同步存放处（`makeStream` 是 nonisolated，不能直接写 actor 状态）。
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Task<Void, Never>?

    var value: Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ task: Task<Void, Never>?) {
        lock.lock()
        storage = task
        lock.unlock()
    }
}

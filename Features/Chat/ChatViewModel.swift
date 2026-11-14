import Foundation
import Combine
import DFCore
import DFAI
import DFOrchestration

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [Message] = []
    @Published var draft: String = ""
    @Published private(set) var isStreaming = false
    @Published var errorText: String?
    @Published private(set) var hasModel: Bool = false

    private let container: AppContainer
    private var conversationID: String = ""
    private var streamingTask: Task<Void, Never>?

    /// 编排器实例（S5-A 只用于启动恢复，发送链路仍是旧实现）。
    /// 每个页面持有自己的实例与 `pageToken`：归属令牌每页唯一，陈旧页面无法取消新轮次。
    private let orchestrator: ChatOrchestratorImpl
    private let pageToken: UUID
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

    func onAppear() async {
        do {
            let conversation = try await container.conversations.ensureMainConversation(title: "大肥鱼")
            conversationID = conversation.id

            await recoverIfNeeded(conversationID: conversation.id)

            // S5-A 保持原有可见历史范围（300 条）；分页接口与分页 UI 统一延后到 S5-D
            messages = try await container.messages.recentMessages(in: conversation.id, limit: 300)
            hasModel = (try await container.modelConfigs.defaultConfig()) != nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        draft = ""
        streamingTask = Task {
            await performSend(text: text)
            streamingTask = nil
        }
    }

    func retry(_ message: Message) {
        guard !isStreaming else { return }
        streamingTask = Task {
            await softDelete(message)
            if message.role == .user {
                await performSend(text: message.text)
            } else {
                await requestReply()
            }
            streamingTask = nil
        }
    }

    func delete(_ message: Message) {
        guard !isStreaming else { return }
        Task {
            await softDelete(message)
        }
    }

    // MARK: - 内部流程

    /// 启动恢复（S4-A 屏障在编排器内部生效）。
    ///
    /// 守卫规则：
    /// 1. 本 VM 已成功恢复过 → 不重复恢复；
    /// 2. 旧发送链路仍在生成（`streamingTask != nil`）→ 跳过恢复，
    ///    否则会把正在生成的消息误改成 `failed`（旧链路不经过编排器，
    ///    编排器拿不到活跃组 id，无法自行排除）；
    /// 3. 跳过恢复时不影响后续的消息装载；
    /// 4. 恢复失败不置成功标志，允许下次 `onAppear` 重试。
    private func recoverIfNeeded(conversationID: String) async {
        guard !hasRecovered, streamingTask == nil else { return }
        do {
            let report = try await orchestrator.recoverStaleTurns(conversationID: conversationID)
            hasRecovered = true
            if !report.failures.isEmpty {
                NSLog("启动恢复存在未完成项：\(report.failures.joined(separator: "；"))")
            }
        } catch {
            // 不阻断进入页面：保留错误信息，且不置 hasRecovered，下次可重试
            NSLog("启动恢复失败：\(error.localizedDescription)")
            errorText = error.localizedDescription
        }
    }

    private func performSend(text: String) async {
        guard !isStreaming else { return }
        isStreaming = true
        defer { isStreaming = false }

        do {
            if conversationID.isEmpty {
                conversationID = try await container.conversations.ensureMainConversation(title: "大肥鱼").id
            }

            var userMessage = Message(
                conversationID: conversationID,
                role: .user,
                text: text,
                status: .sending,
                origin: .user
            )
            try await container.messages.insert(userMessage)
            messages.append(userMessage)

            userMessage = userMessage.markingSent()
            try await container.messages.update(userMessage)
            replace(userMessage)

            try await container.conversations.touch(id: conversationID, at: Clock.nowMillis())
            await requestReply()
        } catch {
            if var last = messages.last, last.role == .user, last.status == .sending {
                last.status = .failed
                replace(last)
                try? await container.messages.update(last)
            }
            errorText = error.localizedDescription
        }
    }

    private func requestReply() async {
        do {
            guard let config = try await container.modelConfigs.defaultConfig() else {
                hasModel = false
                throw DFError.notConfigured("默认模型（请到设置页添加）")
            }
            hasModel = true

            let provider = try container.provider(for: config)
            let corePrompt = (try await container.personas.coreSystemPrompt()) ?? ""

            let history = messages
                .filter { $0.status != .failed && !$0.text.isEmpty }
                .suffix(20)
                .map { message in
                    ChatTurn(
                        role: message.role == .user ? .user : .assistant,
                        text: message.text
                    )
                }

            let composed = PromptComposer.compose(
                PromptInput(corePersona: corePrompt, history: Array(history)),
                budget: PromptBudget(totalTokens: 6000)
            )

            let request = ChatRequest(
                model: config.modelID,
                systemPrompt: composed.system,
                messages: composed.messages.isEmpty
                    ? [ChatTurn(role: .user, text: "（继续）")]
                    : composed.messages,
                temperature: 0.85
            )

            var assistant = Message(
                conversationID: conversationID,
                role: .assistant,
                text: "",
                status: .sending,
                origin: .reply,
                modelConfigID: config.id
            )
            try await container.messages.insert(assistant)
            messages.append(assistant)

            for try await delta in provider.stream(request) {
                switch delta {
                case .text(let chunk):
                    assistant.text += chunk
                    replace(assistant)
                case .usage, .finished:
                    break
                }
            }

            guard !assistant.text.isEmpty else {
                throw DFError.decoding("模型没有返回任何内容")
            }

            assistant.status = .sent
            assistant.sentAt = Clock.nowMillis()
            try await container.messages.update(assistant)
            replace(assistant)
            try await container.conversations.touch(id: conversationID, at: Clock.nowMillis())
        } catch {
            if var last = messages.last, last.role == .assistant, last.status == .sending {
                last.status = .failed
                replace(last)
                try? await container.messages.update(last)
            }
            errorText = error.localizedDescription
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

    private func replace(_ message: Message) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        }
    }
}

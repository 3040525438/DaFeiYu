import Foundation
import Combine
import DFCore
import DFAI

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

    init(container: AppContainer) {
        self.container = container
    }

    func onAppear() async {
        do {
            let conversation = try await container.conversations.ensureMainConversation(title: "大肥鱼")
            conversationID = conversation.id

            try await repairStaleSendingMessages()

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
        }
    }

    func delete(_ message: Message) {
        guard !isStreaming else { return }
        Task {
            await softDelete(message)
        }
    }

    // MARK: - 内部流程

    /// 上次进程被系统杀掉时，可能残留 sending 状态的消息。
    /// 启动时统一标记为 failed，避免出现永远"发送中"的假状态。
    private func repairStaleSendingMessages() async throws {
        let recent = try await container.messages.recentMessages(in: conversationID, limit: 300)
        for var message in recent where message.status == .sending {
            message.status = .failed
            try await container.messages.update(message)
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

import Foundation
import DFCore
import DFData

/// 回合结束后的记忆抽取编排（W8-3）。
///
/// 边界：
/// - 只读本轮原文，不修改消息；
/// - 模型输出必须先过 `MemoryExtractionParser`（证据定位 + 去重 + 预算）；
/// - 任何失败都静默返回 nil，绝不影响聊天与已落库的消息；
/// - 是否启用由调用方注入的 `isEnabled` 决定（读取用户设置）。
public struct MemoryExtractionCoordinator: Sendable {
    public typealias RequestFactory = @Sendable (_ systemPrompt: String, _ userMessage: String) async throws -> ChatRequest
    public typealias ProviderFactory = @Sendable () async throws -> any ChatModelProvider

    private let processing: MemoryProcessingService
    private let makeRequest: RequestFactory
    private let makeProvider: ProviderFactory
    private let isEnabled: @Sendable () async -> Bool
    private let policy: MemoryExtractionPolicy
    /// 模型输出上限，防止异常长回复拖慢后台任务
    private let maxResponseCharacters: Int

    public init(
        processing: MemoryProcessingService,
        makeRequest: @escaping RequestFactory,
        makeProvider: @escaping ProviderFactory,
        isEnabled: @escaping @Sendable () async -> Bool = { true },
        policy: MemoryExtractionPolicy = .default,
        maxResponseCharacters: Int = 8_000
    ) {
        self.processing = processing
        self.makeRequest = makeRequest
        self.makeProvider = makeProvider
        self.isEnabled = isEnabled
        self.policy = policy
        self.maxResponseCharacters = maxResponseCharacters
    }

    /// 处理一个已完成回合。返回 nil 表示未启用、无候选或失败。
    @discardableResult
    public func handle(_ completion: ChatTurnCompletion) async -> MemoryIngestReport? {
        guard await isEnabled() else { return nil }

        let input = MemoryExtractionInput(
            userText: completion.userText,
            assistantText: completion.assistantText
        )
        let sourceText = completion.userText + "\n" + completion.assistantText

        let request: ChatRequest
        let provider: any ChatModelProvider
        do {
            request = try await makeRequest(
                MemoryExtractionPrompt.system,
                MemoryExtractionPrompt.userMessage(for: input)
            )
            provider = try await makeProvider()
        } catch {
            return nil
        }

        let raw: String
        do {
            raw = try await collect(provider.stream(request))
        } catch {
            return nil
        }

        let screened = MemoryExtractionParser.parse(raw, sourceText: sourceText, policy: policy)
        guard !screened.accepted.isEmpty else { return nil }

        let turn = MemoryTurnSource(
            conversationID: completion.conversationID,
            userMessageID: completion.userMessageID,
            assistantMessageID: completion.assistantMessageID,
            text: sourceText,
            at: completion.completedAt
        )
        return try? await processing.ingest(screened.accepted, from: turn)
    }

    /// 收集流式输出，超长即截断（解析器只取第一个 JSON 数组）。
    private func collect(_ stream: AsyncThrowingStream<ChatDelta, Error>) async throws -> String {
        var text = ""
        for try await delta in stream {
            switch delta {
            case .text(let chunk):
                text += chunk
                if text.count > maxResponseCharacters {
                    return text
                }
            case .usage, .finished:
                continue
            }
        }
        return text
    }
}

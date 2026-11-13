import Foundation
import DFCore

/// 本地 Mock Provider。
/// 用途仅限单元测试与离线界面调试，正式包中不会自动选中它。
public struct MockProvider: ChatModelProvider, Sendable {
    public let identifier: String = "mock"
    public let capabilities: ModelCapabilities = [.text]

    private let reply: String
    private let delayNanoseconds: UInt64

    public init(reply: String = "（Mock）收到，这是用于调试的固定回复。", delayNanoseconds: UInt64 = 10_000_000) {
        self.reply = reply
        self.delayNanoseconds = delayNanoseconds
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error> {
        let text = reply
        let delay = delayNanoseconds
        return AsyncThrowingStream { continuation in
            let task = Task {
                for character in text {
                    if Task.isCancelled {
                        continuation.finish(throwing: DFError.cancelled)
                        return
                    }
                    continuation.yield(.text(String(character)))
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: delay)
                    }
                }
                continuation.yield(.usage(Usage(promptTokens: 0, completionTokens: 0)))
                continuation.yield(.finished(.stop))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

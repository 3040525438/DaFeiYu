import XCTest
import DFCore
@testable import DFData

/// D04：结构化输出优先走 JSON 模式，端点不支持时只在请求阶段被拒后回退。
final class StructuredChatRunnerTests: XCTestCase {
    func testUsesJSONModeByDefault() async throws {
        let provider = RecordingProvider { _ in nil }
        let request = ChatRequest(model: "m", systemPrompt: "s", messages: [])
        let result = try await StructuredChatRunner.run(provider: provider, request: request)

        XCTAssertEqual(provider.formats, [.jsonObject])
        XCTAssertEqual(result.text, "{\"ok\":true}")
        XCTAssertEqual(result.usage?.completionTokens, 3)
    }

    func testFallsBackWhenEndpointRejectsJSONMode() async throws {
        // 只对带 response_format 的请求报 400，模拟不支持该字段的兼容端点
        let provider = RecordingProvider { request in
            request.responseFormat == nil ? nil : DFError.http(status: 400, message: "unknown field response_format")
        }
        let request = ChatRequest(model: "m", systemPrompt: "s", messages: [])
        let result = try await StructuredChatRunner.run(provider: provider, request: request)

        XCTAssertEqual(provider.formats, [.jsonObject, nil], "只回退一次，且去掉 response_format")
        XCTAssertEqual(result.text, "{\"ok\":true}")
    }

    func testDoesNotRetryOnNetworkError() async throws {
        let provider = RecordingProvider { _ in DFError.network("断网") }
        let request = ChatRequest(model: "m", systemPrompt: "s", messages: [])
        do {
            _ = try await StructuredChatRunner.run(provider: provider, request: request)
            XCTFail("网络错误必须直接抛出")
        } catch let error as DFError {
            XCTAssertEqual(error, .network("断网"))
        }
        XCTAssertEqual(provider.formats.count, 1, "网络错误不重试，避免无谓计费")
    }

    func testCollectReturnsTextOnly() async throws {
        let provider = RecordingProvider { _ in nil }
        let request = ChatRequest(model: "m", systemPrompt: "s", messages: [])
        let text = try await StructuredChatRunner.collect(provider: provider, request: request)
        XCTAssertEqual(text, "{\"ok\":true}")
    }
}

/// 记录每次请求声明的 response_format；`fail` 返回错误时直接失败。
private final class RecordingProvider: ChatModelProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ChatResponseFormat?] = []
    private let fail: @Sendable (ChatRequest) -> DFError?

    init(fail: @escaping @Sendable (ChatRequest) -> DFError?) {
        self.fail = fail
    }

    var identifier: String { "structured-recording" }
    var capabilities: ModelCapabilities { [.text] }

    var formats: [ChatResponseFormat?] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error> {
        lock.lock()
        recorded.append(request.responseFormat)
        lock.unlock()

        let error = fail(request)
        return AsyncThrowingStream { continuation in
            if let error {
                continuation.finish(throwing: error)
                return
            }
            continuation.yield(.text("{\"ok\""))
            continuation.yield(.text(":true}"))
            continuation.yield(.usage(Usage(promptTokens: 10, completionTokens: 3)))
            continuation.finish()
        }
    }
}

// 该实现依赖 URLSession.AsyncBytes（流式读取）。
// 目前只在 Apple 平台编译：Linux CI 只验证跨平台的 SSEParser 与 MockProvider，
// 避免把无法在本地验证的 Linux 网络栈行为当作已通过。
#if canImport(Darwin)

import Foundation
import DFCore

/// OpenAI 兼容协议的流式 Provider。
/// 只要服务端提供 /chat/completions 的 SSE 流，就可以用这一套适配。
public struct OpenAICompatibleProvider: ChatModelProvider, Pingable, Sendable {
    public let identifier: String
    public let capabilities: ModelCapabilities

    private let baseURL: URL
    private let apiKey: String
    private let modelID: String
    private let session: URLSession

    public init(
        baseURL: URL,
        apiKey: String,
        modelID: String,
        identifier: String = "openai-compatible",
        capabilities: ModelCapabilities = [.text, .vision],
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.modelID = modelID
        self.identifier = identifier
        self.capabilities = capabilities
        self.session = session
    }

    private var completionsURL: URL {
        baseURL.appendingPathComponent("chat/completions", isDirectory: false)
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var urlRequest = URLRequest(url: completionsURL)
                    urlRequest.httpMethod = "POST"
                    urlRequest.timeoutInterval = 90
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    urlRequest.httpBody = try Self.makeBody(request)

                    let (bytes, response) = try await session.bytes(for: urlRequest)

                    guard let http = response as? HTTPURLResponse else {
                        throw DFError.network("响应格式异常")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 2000 { break }
                        }
                        throw DFError.http(status: http.statusCode, message: Self.sanitize(body))
                    }

                    // OpenAI 兼容的 SSE 每个 data 行就是一个完整 JSON，
                    // 这里按行直接解析，不依赖空行来划分事件边界。
                    var sawText = false
                    var firstPayload: String?

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let payload = Self.dataPayload(from: line) else { continue }
                        if firstPayload == nil {
                            firstPayload = payload
                        }

                        if payload == "[DONE]" {
                            continuation.yield(.finished(.stop))
                            continuation.finish()
                            return
                        }
                        guard let decoded = Self.decodeChunk(payload) else { continue }
                        if let text = decoded.text, !text.isEmpty {
                            sawText = true
                            continuation.yield(.text(text))
                        }
                        if let usage = decoded.usage {
                            continuation.yield(.usage(usage))
                        }
                        if let finish = decoded.finish {
                            continuation.yield(.finished(finish))
                        }
                    }

                    guard sawText else {
                        let preview = Self.sanitize(firstPayload ?? "（无 data 行）")
                        throw DFError.decoding("上游没有返回可识别的流式文本，首段内容：\(preview)")
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: DFError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// 连通性测试：发一条极短消息，拿到首个文本片段即视为成功
    public func ping() async throws -> String {
        let request = ChatRequest(
            model: modelID,
            systemPrompt: "只回复两个字：你好",
            messages: [ChatTurn(role: .user, text: "ping")],
            temperature: 0,
            maxTokens: 16
        )

        for try await delta in stream(request) {
            if case .text(let text) = delta, !text.isEmpty {
                return text
            }
        }
        return ""
    }

    // MARK: - 编解码

    private struct WireMessage: Encodable {
        let role: String
        let content: String
    }

    private struct RequestBody: Encodable {
        let model: String
        let messages: [WireMessage]
        let stream: Bool
        let temperature: Double
        let max_tokens: Int?
    }

    private static func makeBody(_ request: ChatRequest) throws -> Data {
        var messages: [WireMessage] = []
        if !request.systemPrompt.isEmpty {
            messages.append(WireMessage(role: "system", content: request.systemPrompt))
        }
        messages.append(contentsOf: request.messages.map {
            WireMessage(role: $0.role.rawValue, content: $0.text)
        })

        let body = RequestBody(
            model: request.model,
            messages: messages,
            stream: true,
            temperature: request.temperature,
            max_tokens: request.maxTokens
        )
        return try JSONEncoder().encode(body)
    }

    private struct UsagePayload: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
    }

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
            }
            let delta: Delta?
            let finish_reason: String?
        }
        let choices: [Choice]?
        let usage: UsagePayload?
    }

    /// 取一行 SSE 文本中的 data 字段；空行、注释行、event/id 等其他字段返回 nil
    private static func dataPayload(from rawLine: String) -> String? {
        var line = rawLine
        if line.hasSuffix("\r") {
            line.removeLast()
        }
        guard line.hasPrefix("data:") else { return nil }

        var payload = String(line.dropFirst("data:".count))
        if payload.hasPrefix(" ") {
            payload.removeFirst()
        }
        return payload
    }

    private static func decodeChunk(_ data: String) -> (text: String?, usage: Usage?, finish: FinishReason?)? {
        guard let payload = data.data(using: .utf8) else { return nil }
        guard let chunk = try? JSONDecoder().decode(StreamChunk.self, from: payload) else {
            return nil
        }

        let choice = chunk.choices?.first
        let usage = chunk.usage.map {
            Usage(promptTokens: $0.prompt_tokens ?? 0, completionTokens: $0.completion_tokens ?? 0)
        }

        var finish: FinishReason?
        if let rawFinish = choice?.finish_reason {
            switch rawFinish {
            case "stop": finish = .stop
            case "length": finish = .length
            default: finish = .unknown
            }
        } else {
            finish = nil
        }

        return (choice?.delta?.content, usage, finish)
    }

    /// 错误信息脱敏：不把密钥或超长响应写进日志/界面
    private static func sanitize(_ text: String) -> String {
        var result = text
        if let range = result.range(of: "sk-") {
            let tail = result[range.lowerBound...].prefix(12)
            result = result.replacingOccurrences(of: String(tail), with: "sk-***")
        }
        return String(result.prefix(500))
    }
}

#endif

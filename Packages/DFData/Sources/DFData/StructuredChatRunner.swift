import Foundation
import DFCore

/// D04：结构化输出的统一入口。
///
/// 内部结构化任务（日记、反思、自主洞察、主动意图）都需要模型返回 JSON。
/// 这里优先要求服务端用 `response_format=json_object`，让模型少产生解释性文字；
/// 但并非所有 OpenAI 兼容端点都支持该字段，因此：
/// - 只在**请求阶段被拒**（4xx，尚未推理、不产生费用）时退回纯提示词模式；
/// - 退回后仍由 `StructuredOutput.parse` 从文本里提取 JSON，不依赖服务端能力。
enum StructuredChatRunner {
    struct Result: Sendable {
        var text: String
        var usage: Usage?
    }

    static func run(provider: any ChatModelProvider, request: ChatRequest) async throws -> Result {
        do {
            return try await run(provider: provider, request: request, jsonMode: true)
        } catch let error as DFError {
            guard case .http(let status, _) = error, (400..<500).contains(status) else { throw error }
            // 端点不认识 response_format：撤回该字段重试一次
            return try await run(provider: provider, request: request, jsonMode: false)
        }
    }

    static func collect(provider: any ChatModelProvider, request: ChatRequest) async throws -> String {
        try await run(provider: provider, request: request).text
    }

    private static func run(
        provider: any ChatModelProvider,
        request: ChatRequest,
        jsonMode: Bool
    ) async throws -> Result {
        var current = request
        current.responseFormat = jsonMode ? .jsonObject : nil

        var raw = ""
        var usage: Usage?
        for try await delta in provider.stream(current) {
            if Task.isCancelled { throw DFError.cancelled }
            switch delta {
            case .text(let piece):
                raw += piece
            case .usage(let value):
                usage = value
            case .finished:
                break
            }
        }
        return Result(text: raw, usage: usage)
    }
}

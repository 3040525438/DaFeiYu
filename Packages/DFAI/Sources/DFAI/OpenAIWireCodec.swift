import Foundation
import DFCore

// 请求体编解码单独成文件且不依赖 URLSession，
// 这样 Linux CI 也能覆盖"发出去的 JSON 到底长什么样"。

/// OpenAI 兼容协议的请求体编码。
enum OpenAIWireCodec {
    struct WireMessage: Encodable {
        let role: String
        let text: String
        let images: [ChatImage]

        private enum CodingKeys: String, CodingKey {
            case role, content
        }

        private enum PartKeys: String, CodingKey {
            case type, text, image_url
        }

        private struct ImageURL: Encodable {
            let url: String
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)
            guard !images.isEmpty else {
                try container.encode(text, forKey: .content)
                return
            }
            var parts = container.nestedUnkeyedContainer(forKey: .content)
            var textPart = parts.nestedContainer(keyedBy: PartKeys.self)
            try textPart.encode("text", forKey: .type)
            try textPart.encode(text, forKey: .text)
            for image in images {
                var imagePart = parts.nestedContainer(keyedBy: PartKeys.self)
                try imagePart.encode("image_url", forKey: .type)
                try imagePart.encode(ImageURL(url: image.dataURL), forKey: .image_url)
            }
        }
    }

    /// D10：请求末尾附带 usage，才能把成本记为"已确认"而不是"估算"
    struct StreamOptions: Encodable {
        let include_usage: Bool
    }

    struct RequestBody: Encodable {
        let model: String
        let messages: [WireMessage]
        let stream: Bool
        let stream_options: StreamOptions
        let temperature: Double
        let max_tokens: Int?
        /// D04：仅当调用方声明时才发送（nil 会被合成的 encodeIfPresent 省略）
        let response_format: ResponseFormatPayload?
    }

    struct ResponseFormatPayload: Encodable {
        let type: String
    }

    static func makeBody(_ request: ChatRequest) throws -> Data {
        var messages: [WireMessage] = []
        if !request.systemPrompt.isEmpty {
            messages.append(WireMessage(role: "system", text: request.systemPrompt, images: []))
        }
        messages.append(contentsOf: request.messages.map {
            WireMessage(role: $0.role.rawValue, text: $0.text, images: $0.images)
        })

        let body = RequestBody(
            model: request.model,
            messages: messages,
            stream: true,
            stream_options: StreamOptions(include_usage: true),
            temperature: request.temperature,
            max_tokens: request.maxTokens,
            response_format: request.responseFormat.map { ResponseFormatPayload(type: $0.rawValue) }
        )
        return try JSONEncoder().encode(body)
    }
}

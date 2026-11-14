import Foundation

public struct ModelCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let text = ModelCapabilities(rawValue: 1 << 0)
    public static let vision = ModelCapabilities(rawValue: 1 << 1)
    public static let toolCalling = ModelCapabilities(rawValue: 1 << 2)
    public static let jsonMode = ModelCapabilities(rawValue: 1 << 3)
    public static let embedding = ModelCapabilities(rawValue: 1 << 4)
}

public enum ChatTurnRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

/// 随消息一起发送的图片（D71）：OpenAI 兼容协议用 data URL。
public struct ChatImage: Codable, Hashable, Sendable {
    public var mimeType: String
    /// Base64（不含前缀）
    public var base64: String

    public init(mimeType: String, base64: String) {
        self.mimeType = mimeType
        self.base64 = base64
    }

    public var dataURL: String {
        "data:\(mimeType);base64,\(base64)"
    }
}

public struct ChatTurn: Codable, Hashable, Sendable {
    public var role: ChatTurnRole
    public var text: String
    /// 仅用户轮次允许带图；空数组时按纯文本编码
    public var images: [ChatImage]

    public init(role: ChatTurnRole, text: String, images: [ChatImage] = []) {
        self.role = role
        self.text = text
        self.images = images
    }

    private enum CodingKeys: String, CodingKey {
        case role, text, images
    }

    /// 容忍旧数据没有 `images` 字段
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(ChatTurnRole.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        images = try container.decodeIfPresent([ChatImage].self, forKey: .images) ?? []
    }
}

public struct ChatRequest: Sendable {
    public var model: String
    public var systemPrompt: String
    public var messages: [ChatTurn]
    public var temperature: Double
    public var maxTokens: Int?

    public init(
        model: String,
        systemPrompt: String,
        messages: [ChatTurn],
        temperature: Double = 0.8,
        maxTokens: Int? = nil
    ) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
}

public struct Usage: Sendable, Equatable {
    public var promptTokens: Int
    public var completionTokens: Int

    public init(promptTokens: Int, completionTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

public enum FinishReason: String, Sendable {
    case stop
    case length
    case unknown
}

public enum ChatDelta: Sendable {
    case text(String)
    case usage(Usage)
    case finished(FinishReason)
}

public protocol ChatModelProvider: Sendable {
    var identifier: String { get }
    var capabilities: ModelCapabilities { get }
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error>
}

/// 可做连通性测试的 Provider（设置页使用）
public protocol Pingable: Sendable {
    func ping() async throws -> String
}

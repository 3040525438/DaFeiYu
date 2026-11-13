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

public struct ChatTurn: Codable, Hashable, Sendable {
    public var role: ChatTurnRole
    public var text: String

    public init(role: ChatTurnRole, text: String) {
        self.role = role
        self.text = text
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

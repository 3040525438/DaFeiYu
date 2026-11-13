import Foundation

public protocol ConversationRepository: Sendable {
    /// 确保存在 main 会话；不存在则创建。必须幂等。
    func ensureMainConversation(title: String) async throws -> Conversation
    func conversation(id: String) async throws -> Conversation?
    func touch(id: String, at millis: Int64) async throws
}

public protocol MessageRepository: Sendable {
    func insert(_ message: Message) async throws
    func update(_ message: Message) async throws
    func message(id: String) async throws -> Message?
    /// 按 created_at 升序返回最近 limit 条（返回结果内部为升序）
    func recentMessages(in conversationID: String, limit: Int) async throws -> [Message]
    func count(in conversationID: String) async throws -> Int
}

/// 注意：本协议刻意不提供 updateCore / deleteCore。
/// 核心人格只能通过"用户显式编辑"或"AstrBot 迁移"写入，
/// 由 PersonaRepository 的实现内部方法完成，AI 侧无法触达。
public protocol PersonaRepository: Sendable {
    func corePersona() async throws -> Persona?
    func coreSystemPrompt() async throws -> String?
    func outerItems() async throws -> [PersonaItem]
    func ensureCorePersona(name: String, systemPrompt: String) async throws -> Persona
}

public protocol ModelConfigRepository: Sendable {
    func all() async throws -> [ModelConfig]
    func defaultConfig() async throws -> ModelConfig?
    func config(id: String) async throws -> ModelConfig?
    func save(_ config: ModelConfig) async throws
    func delete(id: String) async throws
    func makeDefault(id: String) async throws
}

public protocol SettingsRepository: Sendable {
    func string(for key: String) async throws -> String?
    func set(_ value: String, for key: String) async throws
}

/// 密钥存储抽象。iOS 实现为 Keychain，其他平台实现直接抛错（防止误以为已安全保存）。
public protocol SecureStore: Sendable {
    func set(_ value: String, for key: String) throws
    func get(_ key: String) throws -> String?
    func delete(_ key: String) throws
}

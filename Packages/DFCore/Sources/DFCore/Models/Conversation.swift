import Foundation

/// 会话（第一阶段只有 main 一种，保留 kind 以便后续扩展个人空间等）
public struct Conversation: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var kind: String
    public var createdAt: Int64
    public var updatedAt: Int64
    public var archivedAt: Int64?

    public init(
        id: String = UUID().uuidString,
        title: String,
        kind: String = "main",
        createdAt: Int64 = Clock.nowMillis(),
        updatedAt: Int64 = Clock.nowMillis(),
        archivedAt: Int64? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case kind
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case archivedAt = "archived_at"
    }
}

import Foundation

// MARK: - 会话管理

/// 会话列表项。
///
/// 与核心模型 `Conversation` 分离：列表需要未读、置顶、排序、消息计数等可变字段，
/// 若塞进同一个模型，任何一次 `update` 都可能把并发写入的未读数覆盖回旧值。
public struct ConversationSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var kind: String
    public var createdAt: Int64
    public var updatedAt: Int64
    public var archivedAt: Int64?
    /// 置顶时间；非空即置顶
    public var pinnedAt: Int64?
    public var sortIndex: Int
    public var unreadCount: Int
    public var lastReadAt: Int64?
    /// 未软删消息条数
    public var messageCount: Int
    /// 最近一条未软删消息的时间；空会话为 nil
    public var lastMessageAt: Int64?

    public var isPinned: Bool { pinnedAt != nil }
    public var isArchived: Bool { archivedAt != nil }
    public var hasUnread: Bool { unreadCount > 0 }

    public init(
        id: String,
        title: String,
        kind: String,
        createdAt: Int64,
        updatedAt: Int64,
        archivedAt: Int64? = nil,
        pinnedAt: Int64? = nil,
        sortIndex: Int = 0,
        unreadCount: Int = 0,
        lastReadAt: Int64? = nil,
        messageCount: Int = 0,
        lastMessageAt: Int64? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
        self.pinnedAt = pinnedAt
        self.sortIndex = sortIndex
        self.unreadCount = unreadCount
        self.lastReadAt = lastReadAt
        self.messageCount = messageCount
        self.lastMessageAt = lastMessageAt
    }
}

/// 会话列表过滤口径。
public enum ConversationListFilter: String, Sendable, Equatable, CaseIterable {
    /// 未归档（默认列表）
    case active
    /// 仅归档（归档仍可检索、可进入）
    case archived
    /// 全部
    case all
}

public enum ConversationAdminError: Error, Equatable, CustomStringConvertible {
    case notFound
    case emptyTitle
    /// main 会话是用户与 AI 的主线，禁止删除或归档
    case mainConversationProtected

    public var description: String {
        switch self {
        case .notFound: return "会话不存在"
        case .emptyTitle: return "会话标题不能为空"
        case .mainConversationProtected: return "主会话不可删除或归档"
        }
    }
}

/// 会话删除结果。删除会话**只删消息，不删记忆**（D11 / D51）。
public struct ConversationDeletionResult: Sendable, Equatable {
    public var deletedConversations: Int
    public var deletedMessages: Int
    /// 因 main 保护被跳过的数量
    public var skippedProtected: Int

    public init(deletedConversations: Int = 0, deletedMessages: Int = 0, skippedProtected: Int = 0) {
        self.deletedConversations = deletedConversations
        self.deletedMessages = deletedMessages
        self.skippedProtected = skippedProtected
    }
}

/// 多会话管理：建 / 改名 / 置顶 / 归档 / 排序 / 未读 / 删除。
///
/// 排序口径固定为：置顶优先 → `sort_index` 升序 → 最近活动倒序 → id 升序（保证稳定）。
public protocol ConversationAdminRepository: Sendable {
    /// 新建会话（用户手动或 AI 主动；AI 是否允许由上层自主度设置决定，本层不做产品判断）。
    @discardableResult
    func create(title: String, kind: String, at millis: Int64) async throws -> ConversationSummary

    /// 改名。不改 `updated_at`——改名不是"最近活动"，不应打乱列表顺序。
    func rename(id: String, title: String) async throws

    func setPinned(id: String, pinned: Bool, at millis: Int64) async throws

    /// 归档 / 取消归档。main 会话禁止归档。
    func setArchived(id: String, archived: Bool, at millis: Int64) async throws

    /// 按给定顺序重排 `sort_index`；未出现在 `ids` 中的会话保持相对顺序排在后面。
    func reorder(ids: [String]) async throws

    func list(_ filter: ConversationListFilter) async throws -> [ConversationSummary]
    func summary(id: String) async throws -> ConversationSummary?

    /// 未读数增减；负数结果夹取到 0。`millis` 同时作为最近活动时间写入。
    func incrementUnread(id: String, by delta: Int, at millis: Int64) async throws

    /// 单会话已读：未读清零并写 `last_read_at`。
    func markRead(id: String, at millis: Int64) async throws

    /// 全部已读：所有会话未读清零并写 `last_read_at`；返回涉及会话数。
    @discardableResult
    func markAllRead(at millis: Int64) async throws -> Int

    func unreadTotal() async throws -> Int

    /// 删除会话及其全部消息（含 FTS 索引），**保留记忆**；main 会话受保护、计入 `skippedProtected`。
    @discardableResult
    func delete(id: String) async throws -> ConversationDeletionResult

    /// 批量删除；语义同 `delete(id:)`，单事务完成。
    @discardableResult
    func deleteBatch(ids: [String]) async throws -> ConversationDeletionResult
}

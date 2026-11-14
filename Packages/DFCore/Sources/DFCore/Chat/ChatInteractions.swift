import Foundation

// MARK: - 编辑 / 撤回 / 收藏

/// 一条编辑留痕（对应 `message_edits` 一行）。
/// 每次编辑都写全量前后文本，历史不可被覆盖。
public struct MessageEditRecord: Codable, Sendable, Equatable {
    public var messageID: String
    /// 从 1 开始的版本号
    public var version: Int
    public var beforeText: String
    public var afterText: String
    public var editedBy: String
    public var createdAt: Int64

    public init(
        messageID: String,
        version: Int,
        beforeText: String,
        afterText: String,
        editedBy: String = "user",
        createdAt: Int64
    ) {
        self.messageID = messageID
        self.version = version
        self.beforeText = beforeText
        self.afterText = afterText
        self.editedBy = editedBy
        self.createdAt = createdAt
    }
}

public struct MessageEditOutcome: Sendable, Equatable {
    /// 本次编辑后的版本号；内容未变化时返回当前版本且**不**新增留痕
    public var version: Int
    public var editedAt: Int64?
    public var changed: Bool

    public init(version: Int, editedAt: Int64?, changed: Bool) {
        self.version = version
        self.editedAt = editedAt
        self.changed = changed
    }
}

public enum MessageInteractionError: Error, Equatable, CustomStringConvertible {
    case notFound
    case deleted
    case revoked
    case emptyText
    case unchanged

    public var description: String {
        switch self {
        case .notFound: return "消息不存在"
        case .deleted: return "消息已删除，不能编辑或撤回"
        case .revoked: return "消息已撤回"
        case .emptyText: return "消息内容不能为空"
        case .unchanged: return "消息内容没有变化"
        }
    }
}

public protocol MessageEditingRepository: Sendable {
    /// 编辑正文：写一条全量留痕 + 更新正文/编辑时间/编辑次数 + 同步全文索引。
    /// 同一事务完成；内容未变化时不写留痕（`changed == false`）。
    func editMessage(id: String, newText: String, editedAt: Int64) async throws -> MessageEditOutcome

    /// 撤回：只写 `revoked_at` / `revoke_reason` / `status = recalled`。
    /// **不删除原文**，也不物理删除行；重复撤回是幂等错误（`revoked`）。
    func revokeMessage(id: String, reason: String?, revokedAt: Int64) async throws

    /// 收藏 / 取消收藏。收藏不产生记忆，只影响消息标记。
    func setFavorite(id: String, isFavorite: Bool, at: Int64) async throws

    /// 编辑历史，按版本升序
    func editHistory(messageID: String) async throws -> [MessageEditRecord]
}

// MARK: - 删除体系

/// 删除范围（四类删除共用同一软删语义）。
public enum MessageDeleteScope: Sendable, Equatable {
    /// 逐条删除（选中的 id）
    case ids([String])
    /// 按日期区间删除：`created_at ∈ [from, to)`，nil 表示不设该端边界
    case dateRange(fromMillis: Int64?, toMillis: Int64?)
    /// 按关键词筛选删除：对正文做不区分大小写的包含匹配
    case keyword(String)
    /// 清空整个会话的消息（软删）
    case conversation(String)
}

public protocol MessageDeletionRepository: Sendable {
    /// 软删并返回**真实**影响条数。
    /// - Parameter conversationID: 非空时，`ids / dateRange / keyword` 都只在该会话内生效，
    ///   防止越界删除其它会话；`conversation` 范围以其自身参数为准。
    /// - Note: 已软删的消息不会被重复计数；同时移除其全文索引。
    func softDelete(
        _ scope: MessageDeleteScope,
        in conversationID: String?,
        at millis: Int64
    ) async throws -> Int
}

// MARK: - 会话内搜索

public struct ChatSearchHit: Sendable, Equatable, Identifiable {
    public var messageID: String
    public var conversationID: String
    /// bm25 相关度，**越小越相关**（SQLite 原值，不做符号翻转）
    public var score: Double

    public var id: String { messageID }

    public init(messageID: String, conversationID: String, score: Double) {
        self.messageID = messageID
        self.conversationID = conversationID
        self.score = score
    }
}

public protocol ChatSearchRepository: Sendable {
    /// 关键词搜索（中文字符串按 bigram 切分后 AND 匹配）。
    /// 只返回未删除、未撤回的消息；`conversationID` 非空时限定会话内搜索。
    func search(query: String, conversationID: String?, limit: Int) async throws -> [ChatSearchHit]

    /// 重建全文索引（历史消息补索引）。返回实际索引条数。
    func rebuildIndex(conversationID: String?) async throws -> Int
}

// MARK: - 主题与气泡个性化

/// 聊天外观设置。所有字段都有合法取值域，坏数据一律回落到默认值。
public struct ChatTheme: Codable, Sendable, Equatable {
    public static let storageKey = "chat.theme.v1"

    public static let themeIDs = ["classic", "warm", "night"]
    public static let backgrounds = ["cream", "plain", "dark"]
    public static let bubbleStyles = ["bubble", "plain"]
    public static let avatarStyles = ["fish", "initial"]
    public static let fontScaleRange: ClosedRange<Double> = 0.85...1.3

    public var themeID: String
    public var background: String
    public var bubbleStyle: String
    public var fontScale: Double
    public var avatarStyle: String

    public static let `default` = ChatTheme(
        themeID: "classic",
        background: "cream",
        bubbleStyle: "bubble",
        fontScale: 1.0,
        avatarStyle: "fish"
    )

    public init(
        themeID: String,
        background: String,
        bubbleStyle: String,
        fontScale: Double,
        avatarStyle: String
    ) {
        self.themeID = themeID
        self.background = background
        self.bubbleStyle = bubbleStyle
        self.fontScale = fontScale
        self.avatarStyle = avatarStyle
    }

    /// 逐字段校验：非法枚举值回落默认，字号夹取到合法区间，NaN 视为默认。
    public func normalized() -> ChatTheme {
        var copy = self
        if !Self.themeIDs.contains(copy.themeID) { copy.themeID = Self.default.themeID }
        if !Self.backgrounds.contains(copy.background) { copy.background = Self.default.background }
        if !Self.bubbleStyles.contains(copy.bubbleStyle) { copy.bubbleStyle = Self.default.bubbleStyle }
        if !Self.avatarStyles.contains(copy.avatarStyle) { copy.avatarStyle = Self.default.avatarStyle }
        if !copy.fontScale.isFinite {
            copy.fontScale = Self.default.fontScale
        } else {
            copy.fontScale = min(max(copy.fontScale, Self.fontScaleRange.lowerBound),
                                 Self.fontScaleRange.upperBound)
        }
        return copy
    }
}

public protocol ChatThemeStoring: Sendable {
    /// 读取主题；未设置或数据损坏时返回默认值（绝不抛错阻断聊天页）
    func load() async throws -> ChatTheme
    func save(_ theme: ChatTheme) async throws
    /// 恢复默认并落库
    @discardableResult
    func reset() async throws -> ChatTheme
}

import Foundation

/// 消息组状态（组级状态机，与 `MessageStatus` 严格分层）
///
/// - `open`     ：组已创建，回复尚未定稿
/// - `complete` ：正常定稿（assistant 必须是 `sent`）
/// - `failed`   ：生成失败（assistant 必须是 `failed`）
/// - `aborted`  ：取消或重试中止（assistant 只能是 `canceled` / `failed`）
///
/// 三个终态均不可再转移，且必须写 `closedAt`。
public enum MessageGroupStatus: String, Codable, Sendable, CaseIterable {
    case open
    case complete
    case failed
    case aborted
}

/// 组的来源。P1.5 只产生 `chat`，其余为后续阶段预留（无写入路径）。
public enum MessageGroupKind: String, Codable, Sendable, CaseIterable {
    case chat
    case proactive
    case imported
}

/// 引用关系类型。P1.5 只产生 `reply` 与 `context`，`quote` 为预留。
public enum ReferenceRelation: String, Codable, Sendable, CaseIterable {
    /// 唯一主引用，同时回填 `messages.reply_to_id`
    case reply
    /// 普通上下文引用
    case context
    /// 引用块（预留）
    case quote
}

/// 一轮对话的消息组。
/// 只承载归属、轮次与开闭状态，不承载任何内容字段；消息始终可独立寻址。
public struct MessageGroup: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var conversationID: String
    /// 会话内轮次，从 1 开始；唯一索引 `ux_message_groups_turn` 兜底并发重号
    public var turnIndex: Int
    public var kind: MessageGroupKind
    public var status: MessageGroupStatus
    public var openedAt: Int64
    /// 非 `open` 状态必须非空
    public var closedAt: Int64?
    public var userMessageID: String?
    public var assistantMessageID: String?

    public init(
        id: String = UUID().uuidString,
        conversationID: String,
        turnIndex: Int,
        kind: MessageGroupKind = .chat,
        status: MessageGroupStatus = .open,
        openedAt: Int64 = Clock.nowMillis(),
        closedAt: Int64? = nil,
        userMessageID: String? = nil,
        assistantMessageID: String? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.turnIndex = turnIndex
        self.kind = kind
        self.status = status
        self.openedAt = openedAt
        self.closedAt = closedAt
        self.userMessageID = userMessageID
        self.assistantMessageID = assistantMessageID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case conversationID = "conversation_id"
        case turnIndex = "turn_index"
        case kind
        case status
        case openedAt = "opened_at"
        case closedAt = "closed_at"
        case userMessageID = "user_message_id"
        case assistantMessageID = "assistant_message_id"
    }
}

public extension MessageGroup {
    /// 终态（complete / failed / aborted）
    var isTerminal: Bool { status != .open }

    /// 终态缺少关闭时间即为破损状态（4.1.5 的强制约束）
    var isMissingClosedAt: Bool { isTerminal && closedAt == nil }
}

/// 一条引用明细。与 `Message.replyToID` 职责分离：
/// `replyToID` 只存唯一主引用，本结构保存全部引用及关系类型。
public struct MessageReference: Codable, Hashable, Sendable {
    public var messageID: String
    public var refMessageID: String
    public var relation: ReferenceRelation
    /// 0...1，模型给出的把握程度；解析器默认 1.0
    public var confidence: Double
    public var reason: String?
    public var createdAt: Int64

    public init(
        messageID: String,
        refMessageID: String,
        relation: ReferenceRelation = .context,
        confidence: Double = 1.0,
        reason: String? = nil,
        createdAt: Int64 = Clock.nowMillis()
    ) {
        self.messageID = messageID
        self.refMessageID = refMessageID
        self.relation = relation
        self.confidence = confidence
        self.reason = reason
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case refMessageID = "ref_message_id"
        case relation
        case confidence
        case reason
        case createdAt = "created_at"
    }
}

import Foundation

/// 消息角色
public enum MessageRole: String, Codable, Sendable, CaseIterable {
    case user
    case assistant
    case system
    case event
}

/// 消息形态
public enum MessageKind: String, Codable, Sendable, CaseIterable {
    case text
    case image
    case voice
    case mixed
    case proactive
}

/// 消息发送状态机：draft → sending → sent / failed
/// 不允许从 sent 回到 sending（除显式撤回后重发），避免重复写入
///
/// `recalled` 与 `canceled` 严格区分：
/// - `recalled`：用户撤回**已发送**的消息（P4 功能，P1.5 保留定义、零使用）
/// - `canceled`：用户取消**生成**，已生成的部分文本保留（P1.5 使用）
public enum MessageStatus: String, Codable, Sendable, CaseIterable {
    case draft
    case sending
    case sent
    case failed
    case recalled
    case canceled
}

/// 消息来源，用于区分用户输入、AI 回复、主动消息与迁移导入
public enum MessageOrigin: String, Codable, Sendable, CaseIterable {
    case user
    case reply
    case proactive
    case imported
    case system
}

public struct Message: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    /// 幂等键：同一条消息重复写入时由数据库唯一索引拦截
    public var clientUUID: String
    public var conversationID: String
    public var role: MessageRole
    public var kind: MessageKind
    public var text: String
    public var status: MessageStatus
    public var origin: MessageOrigin
    public var replyToID: String?
    /// 用户视角时间（毫秒 UTC）
    public var createdAt: Int64
    /// 实际写入完成时间（主动消息补算时会晚于 createdAt）
    public var sentAt: Int64?
    public var modelConfigID: String?
    public var emotionStateID: String?
    public var deletedAt: Int64?
    /// 所属消息组；`nil` 表示 v2 遗留或未分组消息（虚拟组）
    public var groupID: String?
    /// 组内序号，从 0 开始；与 `groupID` 同时为 `nil` 或同时非空
    public var seqInGroup: Int?

    public init(
        id: String = UUID().uuidString,
        clientUUID: String = UUID().uuidString,
        conversationID: String,
        role: MessageRole,
        kind: MessageKind = .text,
        text: String,
        status: MessageStatus = .draft,
        origin: MessageOrigin,
        replyToID: String? = nil,
        createdAt: Int64 = Clock.nowMillis(),
        sentAt: Int64? = nil,
        modelConfigID: String? = nil,
        emotionStateID: String? = nil,
        deletedAt: Int64? = nil,
        groupID: String? = nil,
        seqInGroup: Int? = nil
    ) {
        self.id = id
        self.clientUUID = clientUUID
        self.conversationID = conversationID
        self.role = role
        self.kind = kind
        self.text = text
        self.status = status
        self.origin = origin
        self.replyToID = replyToID
        self.createdAt = createdAt
        self.sentAt = sentAt
        self.modelConfigID = modelConfigID
        self.emotionStateID = emotionStateID
        self.deletedAt = deletedAt
        self.groupID = groupID
        self.seqInGroup = seqInGroup
    }

    enum CodingKeys: String, CodingKey {
        case id
        case clientUUID = "client_uuid"
        case conversationID = "conversation_id"
        case role
        case kind
        case text
        case status
        case origin
        case replyToID = "reply_to_id"
        case createdAt = "created_at"
        case sentAt = "sent_at"
        case modelConfigID = "model_config_id"
        case emotionStateID = "emotion_state_id"
        case deletedAt = "deleted_at"
        case groupID = "group_id"
        case seqInGroup = "seq_in_group"
    }
}

public extension Message {
    /// 是否允许进入发送流程（防止重复点击导致重复消息）
    var canStartSending: Bool {
        status == .draft || status == .failed
    }

    func markingSending() -> Message {
        var copy = self
        copy.status = .sending
        return copy
    }

    func markingSent(at millis: Int64 = Clock.nowMillis()) -> Message {
        var copy = self
        copy.status = .sent
        copy.sentAt = millis
        return copy
    }

    func markingFailed() -> Message {
        var copy = self
        copy.status = .failed
        return copy
    }

    /// 用户取消生成：保留已生成的文本，不写 `sentAt`
    func markingCanceled() -> Message {
        var copy = self
        copy.status = .canceled
        return copy
    }
}

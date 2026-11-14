import Foundation

// MARK: - 主动消息治理（W7-6 / D50）

public enum ProactiveMessageStatus: String, Sendable, CaseIterable {
    case planned
    case sent
    case suppressed
    case failed
    /// 用户删除：只做软删除，保留触发原因以便追溯与"减少类似"
    case deleted
}

/// 用户对主动消息的反馈。`none` 表示尚未表态，不得推断为喜欢或不喜欢。
public enum ProactiveFeedback: String, Sendable, CaseIterable {
    case none
    /// 不感兴趣：同类主动消息应被抑制
    case notInterested = "not_interested"
    /// 减少类似：降低同类主动消息频率
    case reduceSimilar = "reduce_similar"
}

public struct ProactiveMessage: Sendable, Equatable, Identifiable {
    public var id: String
    public var intentID: String?
    public var plannedAt: Int64
    public var text: String
    public var isVoice: Bool
    public var status: ProactiveMessageStatus
    public var suppressReason: String?
    public var notificationID: String?
    public var resolvedAt: Int64?
    public var priority: Int
    public var expiresAt: Int64?
    public var dedupeKey: String?
    public var messageID: String?
    public var sentAt: Int64?
    public var characterID: String?
    public var moodCode: String?
    public var notifyLevel: NotificationLevel
    public var feedback: ProactiveFeedback
    public var feedbackAt: Int64?
    public var isFavorite: Bool
    public var triggerKind: String?
    public var triggerRef: String?

    public init(
        id: String,
        intentID: String?,
        plannedAt: Int64,
        text: String,
        isVoice: Bool,
        status: ProactiveMessageStatus,
        suppressReason: String?,
        notificationID: String?,
        resolvedAt: Int64?,
        priority: Int,
        expiresAt: Int64?,
        dedupeKey: String?,
        messageID: String?,
        sentAt: Int64?,
        characterID: String?,
        moodCode: String?,
        notifyLevel: NotificationLevel,
        feedback: ProactiveFeedback,
        feedbackAt: Int64?,
        isFavorite: Bool,
        triggerKind: String?,
        triggerRef: String?
    ) {
        self.id = id
        self.intentID = intentID
        self.plannedAt = plannedAt
        self.text = text
        self.isVoice = isVoice
        self.status = status
        self.suppressReason = suppressReason
        self.notificationID = notificationID
        self.resolvedAt = resolvedAt
        self.priority = priority
        self.expiresAt = expiresAt
        self.dedupeKey = dedupeKey
        self.messageID = messageID
        self.sentAt = sentAt
        self.characterID = characterID
        self.moodCode = moodCode
        self.notifyLevel = notifyLevel
        self.feedback = feedback
        self.feedbackAt = feedbackAt
        self.isFavorite = isFavorite
        self.triggerKind = triggerKind
        self.triggerRef = triggerRef
    }
}

/// "为什么发这条消息"：给用户看的触发原因，附关联记忆引用（若有）。
public struct ProactiveMessageExplanation: Sendable, Equatable {
    public var messageID: String
    public var triggerKind: String?
    public var triggerRef: String?
    public var intentReason: String?
    public var evidenceJSON: String?
    /// `trigger_ref` 形如 `memory:<id>` 时解析出的记忆 ID
    public var relatedMemoryID: String?

    public init(
        messageID: String,
        triggerKind: String?,
        triggerRef: String?,
        intentReason: String?,
        evidenceJSON: String?,
        relatedMemoryID: String?
    ) {
        self.messageID = messageID
        self.triggerKind = triggerKind
        self.triggerRef = triggerRef
        self.intentReason = intentReason
        self.evidenceJSON = evidenceJSON
        self.relatedMemoryID = relatedMemoryID
    }
}

public enum ProactiveMessageError: Error, Equatable, CustomStringConvertible {
    case notFound(String)
    case invalidState(String)
    case emptyText
    case invalidFeedback(String)

    public var description: String {
        switch self {
        case .notFound(let id): return "主动消息不存在：\(id)"
        case .invalidState(let reason): return "主动消息状态不允许该操作：\(reason)"
        case .emptyText: return "主动消息内容不能为空"
        case .invalidFeedback(let raw): return "未知的反馈类型：\(raw)"
        }
    }
}

/// 关联记忆引用协议：`memory:<记忆ID>`。无引用时返回 nil。
public enum ProactiveTriggerRef {
    public static let memoryPrefix = "memory:"

    public static func memoryID(from ref: String?) -> String? {
        guard let ref, ref.hasPrefix(memoryPrefix) else { return nil }
        let id = String(ref.dropFirst(memoryPrefix.count))
        return id.isEmpty ? nil : id
    }

    public static func memory(_ id: String) -> String {
        memoryPrefix + id
    }
}

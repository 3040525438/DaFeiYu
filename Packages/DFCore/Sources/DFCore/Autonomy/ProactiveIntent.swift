import Foundation

// MARK: - 主动意图（W7-1 / N-20）

/// 意图状态机：planned → delivered / suppressed / failed；生成阶段即可判定 skipped。
public enum ProactiveIntentStatus: String, Sendable, CaseIterable {
    /// 已生成，等待闸门与投递
    case planned
    /// 被五重闸门拦截（保留原因，便于"为什么没收到"）
    case suppressed
    /// 已写入会话并完成通知投递
    case delivered
    /// 模型判断"这次不该说"，不产生消息
    case skipped
    /// 生成或投递过程失败
    case failed
}

/// 一次"我想说这件事"。对应 `conversation_intents` 表。
public struct ProactiveIntent: Sendable, Equatable, Identifiable {
    public var id: String
    public var conversationID: String
    public var topicID: String?
    public var groupID: String?
    /// 与 `ProactiveTrigger.rawValue` 对齐
    public var kind: String
    public var status: ProactiveIntentStatus
    /// 触发来源：autonomy / user / backfill
    public var trigger: String
    public var reason: String
    /// 证据 JSON 数组（逐字来自上下文，不允许模型编造）
    public var evidenceJSON: String
    public var confidence: Double
    public var priority: Int
    public var plannedAt: Int64
    public var expiresAt: Int64?
    public var suppressReason: String?
    /// ai / user / system
    public var decidedBy: String?
    public var createdAt: Int64
    public var resolvedAt: Int64?

    public init(
        id: String,
        conversationID: String,
        topicID: String?,
        groupID: String?,
        kind: String,
        status: ProactiveIntentStatus,
        trigger: String,
        reason: String,
        evidenceJSON: String,
        confidence: Double,
        priority: Int,
        plannedAt: Int64,
        expiresAt: Int64?,
        suppressReason: String?,
        decidedBy: String?,
        createdAt: Int64,
        resolvedAt: Int64?
    ) {
        self.id = id
        self.conversationID = conversationID
        self.topicID = topicID
        self.groupID = groupID
        self.kind = kind
        self.status = status
        self.trigger = trigger
        self.reason = reason
        self.evidenceJSON = evidenceJSON
        self.confidence = confidence
        self.priority = priority
        self.plannedAt = plannedAt
        self.expiresAt = expiresAt
        self.suppressReason = suppressReason
        self.decidedBy = decidedBy
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }

    /// 生成结果：`shouldSend == false` 时没有候选文本。
    public var isActionable: Bool { status == .planned }

    public var proactiveTrigger: ProactiveTrigger {
        ProactiveTrigger(rawValue: kind) ?? .message
    }
}

public enum ProactiveIntentError: Error, Equatable, CustomStringConvertible {
    case invalidOutput(String)
    case emptyContext
    case intentNotFound(String)
    case invalidState(String)
    case conversationMissing(String)
    case emptyMessage

    public var description: String {
        switch self {
        case .invalidOutput(let reason): return "意图输出不合法：\(reason)"
        case .emptyContext: return "缺少可用的上下文，不能凭空生成主动意图"
        case .intentNotFound(let id): return "意图不存在：\(id)"
        case .invalidState(let reason): return "意图状态不允许该操作：\(reason)"
        case .conversationMissing(let id): return "会话不存在：\(id)"
        case .emptyMessage: return "意图候选内容为空"
        }
    }
}

import Foundation

// MARK: - 自主度与发送闸门

/// 通知呈现档位（D48）：完整内容 / 简短提示 / 完全不显示。
public enum NotificationLevel: String, Codable, Sendable, CaseIterable {
    case full
    case brief
    case hidden
}

/// 主动行为的触发类型（D68 分项控制）。
public enum ProactiveTrigger: String, Codable, Sendable, CaseIterable {
    case message
    case newConversation
    case memoryConsolidation
    case selfReflection
    case suggestion
}

/// 自主策略：所有能"打扰用户"或"花预算"的开关都在这里，默认保守。
public struct AutonomyPolicy: Codable, Sendable, Equatable {
    /// 总开关：关闭后任何主动行为都不允许
    public var enabled: Bool
    /// 免打扰区间（分钟计，支持跨午夜，如 23:00–08:00）
    public var quietStartMinute: Int
    public var quietEndMinute: Int
    /// 两条主动消息之间的最小间隔（分钟，D14 默认 120）
    public var minIntervalMinutes: Int
    /// 每日主动消息上限（D14 默认 5）
    public var dailyLimit: Int
    public var notificationLevel: NotificationLevel
    /// 分项开关
    public var allowProactiveMessage: Bool
    public var allowNewConversation: Bool
    public var allowMemoryConsolidation: Bool
    public var allowSelfReflection: Bool
    public var allowSuggestion: Bool

    public static let `default` = AutonomyPolicy(
        enabled: true,
        quietStartMinute: 23 * 60,
        quietEndMinute: 8 * 60,
        minIntervalMinutes: 120,
        dailyLimit: 5,
        notificationLevel: .brief,
        allowProactiveMessage: true,
        allowNewConversation: false,
        allowMemoryConsolidation: true,
        allowSelfReflection: true,
        allowSuggestion: true
    )

    public init(
        enabled: Bool,
        quietStartMinute: Int,
        quietEndMinute: Int,
        minIntervalMinutes: Int,
        dailyLimit: Int,
        notificationLevel: NotificationLevel,
        allowProactiveMessage: Bool,
        allowNewConversation: Bool,
        allowMemoryConsolidation: Bool,
        allowSelfReflection: Bool,
        allowSuggestion: Bool
    ) {
        self.enabled = enabled
        self.quietStartMinute = quietStartMinute
        self.quietEndMinute = quietEndMinute
        self.minIntervalMinutes = minIntervalMinutes
        self.dailyLimit = dailyLimit
        self.notificationLevel = notificationLevel
        self.allowProactiveMessage = allowProactiveMessage
        self.allowNewConversation = allowNewConversation
        self.allowMemoryConsolidation = allowMemoryConsolidation
        self.allowSelfReflection = allowSelfReflection
        self.allowSuggestion = allowSuggestion
    }

    /// 逐项夹取到合法域，坏配置不炸流程。
    public func normalized() -> AutonomyPolicy {
        var copy = self
        copy.quietStartMinute = min(max(copy.quietStartMinute, 0), 1439)
        copy.quietEndMinute = min(max(copy.quietEndMinute, 0), 1439)
        copy.minIntervalMinutes = min(max(copy.minIntervalMinutes, 0), 1440)
        copy.dailyLimit = min(max(copy.dailyLimit, 0), 100)
        return copy
    }

    /// 分项开关是否允许该触发类型
    public func allows(_ trigger: ProactiveTrigger) -> Bool {
        switch trigger {
        case .message: return allowProactiveMessage
        case .newConversation: return allowNewConversation
        case .memoryConsolidation: return allowMemoryConsolidation
        case .selfReflection: return allowSelfReflection
        case .suggestion: return allowSuggestion
        }
    }
}

/// 闸门结论。`reason` 为 nil 表示放行；非 nil 是给用户看的中文原因。
public struct AutonomyDecision: Sendable, Equatable {
    public var allowed: Bool
    public var reason: String?

    public static let allowed = AutonomyDecision(allowed: true, reason: nil)

    public init(allowed: Bool, reason: String?) {
        self.allowed = allowed
        self.reason = reason
    }
}

/// 主动行为闸门：五重检查（总开关 / 分项 / 免打扰 / 最小间隔 / 每日上限）。
///
/// 纯函数，不读时钟、不读库；调用方传入 `now`、上次发送时间与今日已发条数，
/// 便于在 CI 里覆盖跨午夜、边界分钟等场景（D13 / D14 / D54 / D68）。
public enum AutonomyGate {
    /// - Parameters:
    ///   - nowMinuteOfDay: 当前本地时间的"当天第几分钟"（0...1439）
    ///   - lastSentAt: 上次主动消息时间（毫秒）；nil 表示今天还没发过
    ///   - todaySentCount: 今天已发主动消息条数
    public static func evaluate(
        policy: AutonomyPolicy,
        trigger: ProactiveTrigger,
        nowMillis: Int64,
        nowMinuteOfDay: Int,
        lastSentAt: Int64?,
        todaySentCount: Int
    ) -> AutonomyDecision {
        let policy = policy.normalized()
        guard policy.enabled else {
            return AutonomyDecision(allowed: false, reason: "自主行为总开关已关闭")
        }
        guard policy.allows(trigger) else {
            return AutonomyDecision(allowed: false, reason: "该类型主动行为已被单独关闭")
        }
        // 记忆整理与自我反思不打扰用户，不受免打扰与频率限制
        guard trigger == .message || trigger == .newConversation || trigger == .suggestion else {
            return .allowed
        }
        if isQuietHours(policy: policy, minuteOfDay: nowMinuteOfDay) {
            return AutonomyDecision(allowed: false, reason: "当前处于免打扰时段")
        }
        if todaySentCount >= policy.dailyLimit {
            return AutonomyDecision(allowed: false, reason: "已达今日主动消息上限（\(policy.dailyLimit) 条）")
        }
        if let lastSentAt {
            let elapsedMinutes = Double(nowMillis - lastSentAt) / 60_000
            if elapsedMinutes < Double(policy.minIntervalMinutes) {
                let remaining = Int((Double(policy.minIntervalMinutes) - elapsedMinutes).rounded(.up))
                return AutonomyDecision(allowed: false, reason: "距上次主动消息不足最小间隔，还需 \(remaining) 分钟")
            }
        }
        return .allowed
    }

    /// 免打扰判定，支持 start > end 的跨午夜区间；start == end 视为不设免打扰。
    public static func isQuietHours(policy: AutonomyPolicy, minuteOfDay: Int) -> Bool {
        let start = policy.normalized().quietStartMinute
        let end = policy.normalized().quietEndMinute
        guard start != end else { return false }
        let minute = min(max(minuteOfDay, 0), 1439)
        if start < end {
            return minute >= start && minute < end
        }
        // 跨午夜：23:00–08:00 → [start, 1440) ∪ [0, end)
        return minute >= start || minute < end
    }

    /// 计算下一次最早可发送时间；不涉及预算与内容生成，只解时间约束。
    /// - Returns: nil 表示当前已可发送
    public static func nextAllowedMillis(
        policy: AutonomyPolicy,
        nowMillis: Int64,
        nowMinuteOfDay: Int,
        lastSentAt: Int64?,
        todaySentCount: Int
    ) -> Int64? {
        let policy = policy.normalized()
        if !policy.enabled || todaySentCount >= policy.dailyLimit {
            return nil
        }
        let decision = evaluate(
            policy: policy,
            trigger: .message,
            nowMillis: nowMillis,
            nowMinuteOfDay: nowMinuteOfDay,
            lastSentAt: lastSentAt,
            todaySentCount: todaySentCount
        )
        if decision.allowed { return nil }

        var candidates: [Int64] = []
        if let lastSentAt {
            candidates.append(lastSentAt + Int64(policy.minIntervalMinutes) * 60_000)
        }
        if isQuietHours(policy: policy, minuteOfDay: nowMinuteOfDay) {
            // 距免打扰结束还有多少分钟
            let end = policy.quietEndMinute
            var delta = end - nowMinuteOfDay
            if delta <= 0 { delta += 1440 }
            candidates.append(nowMillis + Int64(delta) * 60_000)
        }
        return candidates.max()
    }
}

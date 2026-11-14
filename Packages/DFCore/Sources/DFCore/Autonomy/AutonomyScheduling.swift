import Foundation

// MARK: - 自主任务与执行记录（W7 / D15、D68、W7-5、W7-7）

/// 自主任务状态机：pending → running → done / skipped / failed；过期由 pending → expired。
public enum AutonomyTaskStatus: String, Sendable, CaseIterable {
    case pending
    case running
    case done
    case skipped
    case failed
    case expired
}

/// 自主任务：一个"待执行的自主行为"，`dedupeKey` 唯一，避免同一话题重复排队。
public struct AutonomyTask: Sendable, Equatable, Identifiable {
    public var id: String
    /// 与 `ProactiveTrigger.rawValue` 对齐
    public var kind: String
    public var conversationID: String?
    public var topicID: String?
    public var dedupeKey: String
    public var status: AutonomyTaskStatus
    public var priority: Int
    public var scheduledAt: Int64
    public var expiresAt: Int64?
    public var attempts: Int
    public var maxAttempts: Int
    public var lastAttemptAt: Int64?
    public var payloadJSON: String
    public var resultJSON: String?
    public var error: String?
    public var createdAt: Int64
    public var updatedAt: Int64

    public init(
        id: String,
        kind: String,
        conversationID: String?,
        topicID: String?,
        dedupeKey: String,
        status: AutonomyTaskStatus,
        priority: Int,
        scheduledAt: Int64,
        expiresAt: Int64?,
        attempts: Int,
        maxAttempts: Int,
        lastAttemptAt: Int64?,
        payloadJSON: String,
        resultJSON: String?,
        error: String?,
        createdAt: Int64,
        updatedAt: Int64
    ) {
        self.id = id
        self.kind = kind
        self.conversationID = conversationID
        self.topicID = topicID
        self.dedupeKey = dedupeKey
        self.status = status
        self.priority = priority
        self.scheduledAt = scheduledAt
        self.expiresAt = expiresAt
        self.attempts = attempts
        self.maxAttempts = maxAttempts
        self.lastAttemptAt = lastAttemptAt
        self.payloadJSON = payloadJSON
        self.resultJSON = resultJSON
        self.error = error
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 是否还能重试（未达最大次数且未过期）
    public func canRetry(at millis: Int64) -> Bool {
        guard attempts < maxAttempts else { return false }
        if let expiresAt, expiresAt <= millis { return false }
        return status == .pending || status == .failed
    }
}

/// 执行记录状态：每次放行/拦截/执行/跳过都留痕，供"查看触发原因"与补算排查。
public enum AutonomyRunStatus: String, Sendable {
    case running
    case allowed
    case blocked
    case done
    case skipped
    case failed
}

public struct AutonomyRun: Sendable, Equatable, Identifiable {
    public var id: String
    public var taskID: String?
    public var kind: String
    /// foreground / background / launch_backfill
    public var trigger: String
    public var status: AutonomyRunStatus
    public var decision: String?
    public var blockReason: String?
    public var modelConfigID: String?
    public var startedAt: Int64
    public var finishedAt: Int64?
    public var durationMs: Int64?
    public var detailJSON: String
    public var error: String?

    public init(
        id: String,
        taskID: String?,
        kind: String,
        trigger: String,
        status: AutonomyRunStatus,
        decision: String?,
        blockReason: String?,
        modelConfigID: String?,
        startedAt: Int64,
        finishedAt: Int64?,
        durationMs: Int64?,
        detailJSON: String,
        error: String?
    ) {
        self.id = id
        self.taskID = taskID
        self.kind = kind
        self.trigger = trigger
        self.status = status
        self.decision = decision
        self.blockReason = blockReason
        self.modelConfigID = modelConfigID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.durationMs = durationMs
        self.detailJSON = detailJSON
        self.error = error
    }
}

// MARK: - 通知分档（D48）

/// 通知渲染结果；`nil` 表示按用户设置完全不展示。
public struct NotificationContent: Sendable, Equatable {
    public var title: String
    public var body: String?

    public init(title: String, body: String?) {
        self.title = title
        self.body = body
    }
}

public enum NotificationTiering {
    /// - full：标题 + 正文
    /// - brief：只显示标题，不暴露正文
    /// - hidden：不展示任何内容（消息仍写入会话）
    public static func render(level: NotificationLevel, title: String, body: String) -> NotificationContent? {
        switch level {
        case .full:
            return NotificationContent(title: title, body: body)
        case .brief:
            return NotificationContent(title: title, body: nil)
        case .hidden:
            return nil
        }
    }
}

// MARK: - 后台补算（D15）

public enum AutonomyBackfill {
    /// 需要在启动时补算的每日任务类型（不打扰用户）
    public static let dailyKinds: [ProactiveTrigger] = [.memoryConsolidation, .selfReflection]

    /// 上次成功时间早于今天 0 点（或从未成功）的每日任务需要在本次启动补算。
    public static func missedDailyKinds(
        lastSuccessAt: [ProactiveTrigger: Int64],
        dayStartMillis: Int64
    ) -> [ProactiveTrigger] {
        dailyKinds.filter { kind in
            guard let last = lastSuccessAt[kind] else { return true }
            return last < dayStartMillis
        }
    }

    /// 已到期但仍 pending 的任务（后台被杀、系统未调度），按计划时间升序返回，
    /// 由调用方在启动后按剩余次数重试；过期任务由 `expire` 统一标记，不在此返回。
    public static func overduePending(_ tasks: [AutonomyTask], nowMillis: Int64) -> [AutonomyTask] {
        tasks
            .filter { $0.status == .pending && $0.scheduledAt <= nowMillis }
            .filter { $0.expiresAt == nil || $0.expiresAt! > nowMillis }
            .sorted { $0.scheduledAt < $1.scheduledAt }
    }
}

// MARK: - 时钟

/// 自主调度时钟：把"当前毫秒 / 当天第几分钟 / 当天 0 点"显式注入，便于测试跨日与跨时区。
public struct AutonomyClock: Sendable {
    public var now: @Sendable () -> Int64
    public var minuteOfDay: @Sendable (Int64) -> Int
    public var dayStart: @Sendable (Int64) -> Int64

    public init(
        now: @escaping @Sendable () -> Int64,
        minuteOfDay: @escaping @Sendable (Int64) -> Int,
        dayStart: @escaping @Sendable (Int64) -> Int64
    ) {
        self.now = now
        self.minuteOfDay = minuteOfDay
        self.dayStart = dayStart
    }

    public static let system = AutonomyClock(
        now: { Clock.nowMillis() },
        minuteOfDay: { millis in
            let components = Calendar.current.dateComponents(
                [.hour, .minute],
                from: Date(timeIntervalSince1970: Double(millis) / 1000)
            )
            return (components.hour ?? 0) * 60 + (components.minute ?? 0)
        },
        dayStart: { millis in
            let date = Date(timeIntervalSince1970: Double(millis) / 1000)
            let start = Calendar.current.startOfDay(for: date)
            return Int64(start.timeIntervalSince1970 * 1000)
        }
    )
}

// MARK: - 错误

public enum AutonomyError: Error, Equatable, CustomStringConvertible {
    case taskNotFound(String)
    case taskNotPending(String)
    case invalidPayload(String)
    case retryExhausted(String)
    case invalidStatus(String)

    public var description: String {
        switch self {
        case .taskNotFound(let id): return "自主任务不存在：\(id)"
        case .taskNotPending(let status): return "自主任务不在待执行状态：\(status)"
        case .invalidPayload(let reason): return "任务负载不合法：\(reason)"
        case .retryExhausted(let id): return "自主任务重试次数已用尽：\(id)"
        case .invalidStatus(let raw): return "未知的自主状态：\(raw)"
        }
    }
}

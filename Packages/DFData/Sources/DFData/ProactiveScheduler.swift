import Foundation
import GRDB
import DFCore

/// 主动检查调度（N-20 接线）：把"该不该主动说一句"变成可排队的 `message` 任务。
///
/// 规则（保守，全部可在 CI 覆盖）：
/// 1. 总开关关闭、分项关闭、暂停中 → 不排；
/// 2. 当前时间不在 09:00–21:00 或处于免打扰区间 → 不排；
/// 3. 用户最近 8 小时内说过话 → 不排（避免打断）；
/// 4. 距上一条主动消息不足策略最小间隔、或今日已达上限 → 不排；
/// 5. 其余情况按天去重排一个 `message` 任务，由 `ProactiveIntentRunner` 生成并过闸门。
public final class ProactiveScheduler: @unchecked Sendable {
    public struct Evaluation: Sendable, Equatable {
        public var shouldEnqueue: Bool
        public var reason: String

        public init(shouldEnqueue: Bool, reason: String) {
            self.shouldEnqueue = shouldEnqueue
            self.reason = reason
        }
    }

    /// 用户沉默多久才考虑主动；默认 8 小时
    public let inactivityMinutes: Int
    /// 可主动的时间窗（本地分钟）
    public let earliestMinuteOfDay: Int
    public let latestMinuteOfDay: Int

    private let database: AppDatabase
    private let autonomy: AutonomyService
    private let clock: AutonomyClock

    public init(
        database: AppDatabase,
        autonomy: AutonomyService,
        clock: AutonomyClock = .system,
        inactivityMinutes: Int = 8 * 60,
        earliestMinuteOfDay: Int = 9 * 60,
        latestMinuteOfDay: Int = 21 * 60
    ) {
        self.database = database
        self.autonomy = autonomy
        self.clock = clock
        self.inactivityMinutes = max(1, inactivityMinutes)
        self.earliestMinuteOfDay = earliestMinuteOfDay
        self.latestMinuteOfDay = latestMinuteOfDay
    }

    public func evaluate() async throws -> Evaluation {
        let state = try await autonomy.state()
        let policy = state.policy
        let now = clock.now()
        let minute = clock.minuteOfDay(now)
        let dayStart = clock.dayStart(now)

        guard policy.enabled else {
            return Evaluation(shouldEnqueue: false, reason: "总开关关闭")
        }
        guard policy.allowProactiveMessage else {
            return Evaluation(shouldEnqueue: false, reason: "主动消息分项关闭")
        }
        if let pausedUntil = state.pausedUntil, pausedUntil > now {
            return Evaluation(shouldEnqueue: false, reason: "自主行为暂停中")
        }
        guard minute >= earliestMinuteOfDay, minute <= latestMinuteOfDay else {
            return Evaluation(shouldEnqueue: false, reason: "不在可主动时间窗")
        }
        guard !Self.isQuiet(minute: minute, start: policy.quietStartMinute, end: policy.quietEndMinute) else {
            return Evaluation(shouldEnqueue: false, reason: "处于免打扰时段")
        }

        let stats = try await database.dbQueue.read { db -> (Int64?, Int64?, Int) in
            let lastUser = try Int64.fetchOne(
                db,
                sql: """
                SELECT max(created_at) FROM messages
                 WHERE role = 'user' AND deleted_at IS NULL
                """
            )
            let lastProactive = try Int64.fetchOne(
                db,
                sql: "SELECT max(sent_at) FROM proactive_messages WHERE sent_at IS NOT NULL"
            )
            let todaySent = try Int.fetchOne(
                db,
                sql: """
                SELECT count(*) FROM proactive_messages
                 WHERE sent_at IS NOT NULL AND sent_at >= ?
                """,
                arguments: [dayStart]
            ) ?? 0
            return (lastUser, lastProactive, todaySent)
        }

        let inactivityMillis = Int64(inactivityMinutes) * 60 * 1000
        if let lastUser = stats.0, now - lastUser < inactivityMillis {
            return Evaluation(shouldEnqueue: false, reason: "用户最近说过话")
        }
        let intervalMillis = Int64(policy.minIntervalMinutes) * 60 * 1000
        if let lastProactive = stats.1, now - lastProactive < intervalMillis {
            return Evaluation(shouldEnqueue: false, reason: "距上一条主动消息不足最小间隔")
        }
        guard stats.2 < policy.dailyLimit else {
            return Evaluation(shouldEnqueue: false, reason: "今日主动消息已达上限")
        }

        return Evaluation(shouldEnqueue: true, reason: "用户已沉默超过 \(inactivityMinutes / 60) 小时")
    }

    /// 到点则入队；返回任务（去重命中时返回既有任务），不满足条件返回 nil。
    public func enqueueDueCheckIn() async throws -> AutonomyTask? {
        let evaluation = try await evaluate()
        guard evaluation.shouldEnqueue else { return nil }
        let now = clock.now()
        let dayStart = clock.dayStart(now)
        return try await autonomy.enqueue(
            kind: .message,
            conversationID: nil,
            topicID: nil,
            dedupeKey: "checkin:\(dayStart)",
            priority: 3,
            scheduledAt: now,
            payloadJSON: "{\"reason\":\"inactivity\"}"
        )
    }

    /// 免打扰判断，支持跨午夜区间
    static func isQuiet(minute: Int, start: Int, end: Int) -> Bool {
        if start == end { return false }
        if start < end {
            return minute >= start && minute < end
        }
        return minute >= start || minute < end
    }
}

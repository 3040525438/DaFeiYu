import Foundation

// MARK: - 自动备份调度（W9-2 / D09）

/// 调度动作：跳过 / 每日完整备份 / 数据变更增量备份。
public enum BackupScheduleAction: String, Sendable, Equatable {
    case skip
    case automatic
    case incremental
}

public struct BackupScheduleDecision: Sendable, Equatable {
    public var action: BackupScheduleAction
    /// 给用户看的说明（跳过原因或本次备份理由）
    public var reason: String

    public init(action: BackupScheduleAction, reason: String) {
        self.action = action
        self.reason = reason
    }
}

/// 纯策略：不读时钟、不读库，便于在 CI 覆盖当日/跨日/频繁变更等场景。
///
/// 规则（默认）：
/// 1. 今天还没有自动备份 → 立即做一次完整自动备份；
/// 2. 已有今日备份但数据指纹变化、且距上次增量备份超过 1 小时 → 做增量备份；
/// 3. 其余情况跳过，避免频繁写盘。
public struct BackupSchedulePolicy: Sendable, Equatable {
    /// 两次增量备份的最小间隔（毫秒），默认 1 小时
    public var incrementalMinIntervalMillis: Int64

    public init(incrementalMinIntervalMillis: Int64 = 60 * 60 * 1000) {
        self.incrementalMinIntervalMillis = max(0, incrementalMinIntervalMillis)
    }

    public static let `default` = BackupSchedulePolicy()

    public func decide(
        nowMillis: Int64,
        dayStartMillis: Int64,
        lastAutomaticAt: Int64?,
        lastIncrementalAt: Int64?,
        dataChanged: Bool
    ) -> BackupScheduleDecision {
        if lastAutomaticAt == nil || lastAutomaticAt! < dayStartMillis {
            return BackupScheduleDecision(action: .automatic, reason: "今天还没有自动备份")
        }
        guard dataChanged else {
            return BackupScheduleDecision(action: .skip, reason: "自上次备份后数据没有变化")
        }
        if let lastIncrementalAt,
           nowMillis - lastIncrementalAt < incrementalMinIntervalMillis {
            return BackupScheduleDecision(action: .skip, reason: "距上次增量备份不足最小间隔")
        }
        return BackupScheduleDecision(action: .incremental, reason: "检测到数据变化，执行增量备份")
    }
}

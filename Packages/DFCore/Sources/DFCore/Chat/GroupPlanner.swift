import Foundation

/// 连续用户消息的合组判定结果
public enum GroupAttachDecision: Equatable, Sendable {
    case createNew
    case appendTo(groupID: String)
}

/// 消息组规划的**纯逻辑**模块。
///
/// 边界（r2.2.1）：
/// - 不访问数据库、不执行 SQL、不生成时间戳、不承担并发控制；
/// - 所有标量（当前最大 `turn_index`、组内最大 `seq_in_group`）由仓储查询后传入；
/// - `MAX(turn_index)+1` 的原子性、唯一索引与并发冲突处理属于 A2 的仓储职责。
public enum GroupPlanner {
    /// 下一组的轮次。
    /// 规则：`nil` → 1；`n ≥ 1` → `n+1`；`n ≤ 0` 视为异常输入，返回 1；`Int.max` 饱和返回 `Int.max`。
    public static func nextTurnIndex(after currentMax: Int?) -> Int {
        guard let currentMax, currentMax >= 1 else { return 1 }
        if currentMax == Int.max { return Int.max }
        return currentMax + 1
    }

    /// 组内下一条消息的 `seq_in_group`。
    ///
    /// - Parameter maxSeq: 当前组内**最大** `seq_in_group`，无消息时为 `nil`。
    ///   必须来自**不过滤 `deleted_at`** 的 `SELECT max(seq_in_group)`，
    ///   即包含已软删消息；按"有效消息条数"计算会在软删后重用历史序号。
    public static func nextSeq(afterMaxExisting maxSeq: Int?) -> Int {
        guard let maxSeq, maxSeq >= 0 else { return 0 }
        if maxSeq == Int.max { return Int.max }
        return maxSeq + 1
    }

    /// 组状态转移是否合法。三个终态不可再转移。
    public static func canTransition(_ from: MessageGroupStatus, to: MessageGroupStatus) -> Bool {
        switch from {
        case .open:
            return to != .open
        case .complete, .failed, .aborted:
            return false
        }
    }

    /// 取消 / 页面离开是否应中止该组：仅 `open` 组生效。
    /// 已 `complete` 的组绝不会因普通取消变成 `aborted`。
    public static func shouldAbortOnCancel(_ status: MessageGroupStatus) -> Bool {
        status == .open
    }

    /// 重试时旧组应转成的状态。
    /// - `open` / `failed` → `.aborted`
    /// - `complete` / `aborted` → `nil`（保持不变）
    public static func statusOnRetry(of status: MessageGroupStatus) -> MessageGroupStatus? {
        switch status {
        case .open, .failed:
            return .aborted
        case .complete, .aborted:
            return nil
        }
    }

    /// 校验「组状态 + assistant 消息状态」是否属于方案 4.1.5 的合法组合。
    ///
    /// P1.5 允许的 5 种主组合：
    /// `open+sending`、`complete+sent`、`failed+failed`、`aborted+canceled`、`aborted+failed`。
    /// 另外 `recalled`（用户撤回）与组状态无关，任意组合均放行。
    public static func isValidCombination(group: MessageGroupStatus,
                                          assistant: MessageStatus?) -> Bool {
        // 撤回属于消息侧的单向操作，不改变组归属语义
        if assistant == .recalled { return true }
        switch group {
        case .open:
            return assistant == .sending
        case .complete:
            return assistant == .sent
        case .failed:
            return assistant == .failed
        case .aborted:
            return assistant == .canceled || assistant == .failed
        }
    }

    /// 连续用户消息的合组判定。
    ///
    /// P1.5 **恒返回 `.createNew`**：事务 A 原子插入 user + assistant，
    /// 组一旦创建即进入生成，不存在"攒消息"窗口；UI 在生成期间也禁用发送。
    /// `appendTo` 分支为将来"延迟创建 assistant"的合组机制预留，当前无调用路径。
    public static func decideGroup(existingOpenGroupID: String?,
                                   isGenerating: Bool) -> GroupAttachDecision {
        _ = existingOpenGroupID
        _ = isGenerating
        return .createNew
    }
}

import Foundation

// MARK: - 生成状态（D52）

/// 一轮生成的完整状态机，供界面展示"等待 / 思考 / 生成 / 暂停 / 完成 / 失败 / 停止"。
///
/// 与 `MessageStatus` 严格分层：
/// - `MessageStatus` 是**落库语义**（sending / sent / failed / canceled）；
/// - `ChatTurnPhase` 是**界面语义**，只描述这一刻用户应看到什么，不写库。
///
/// 状态转移（唯一合法路径）：
/// `idle → waiting → thinking → generating ⇄ paused → completed / failed / stopped → idle`
public enum ChatTurnPhase: String, Sendable, Equatable, CaseIterable {
    /// 没有进行中的轮次
    case idle
    /// 已提交发送，尚未拿到开组事件（含预算预占、恢复屏障等待）
    case waiting
    /// 组已打开、请求已发出，但还没有任何可见增量
    case thinking
    /// 正在流式产出可见文本
    case generating
    /// 用户暂停：本轮仍存活，恢复后继续追加
    case paused
    /// 正常完成（事务 B 已提交）
    case completed
    /// 运行期失败
    case failed
    /// 用户停止 / 取消，已生成的部分文本保留
    case stopped

    /// 是否属于"正在进行中"（需要展示停止 / 暂停按钮）
    public var isActive: Bool {
        switch self {
        case .waiting, .thinking, .generating, .paused: return true
        case .idle, .completed, .failed, .stopped: return false
        }
    }

    /// 是否是终态（本轮已收尾）
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .stopped: return true
        default: return false
        }
    }

    /// 给用户看的中文状态文案
    public var label: String {
        switch self {
        case .idle: return "空闲"
        case .waiting: return "正在发送…"
        case .thinking: return "正在思考…"
        case .generating: return "正在生成…"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "生成失败"
        case .stopped: return "已停止"
        }
    }

    /// 状态图标（SF Symbols）
    public var symbolName: String {
        switch self {
        case .idle: return "circle"
        case .waiting: return "paperplane"
        case .thinking: return "ellipsis.bubble"
        case .generating: return "waveform"
        case .paused: return "pause.circle"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .stopped: return "stop.circle"
        }
    }

    /// 是否允许从当前状态转移到目标状态。
    ///
    /// 用于防止"已完成后又被增量改成生成中"这类非法跃迁；
    /// 终态只允许回到 `idle`。
    public func canTransition(to next: ChatTurnPhase) -> Bool {
        if next == .idle { return true }
        switch self {
        case .idle:
            return next == .waiting
        case .waiting:
            return next == .thinking || next == .failed || next == .stopped
        case .thinking:
            return next == .generating || next == .paused
                || next == .failed || next == .stopped || next == .completed
        case .generating:
            return next == .paused || next == .completed
                || next == .failed || next == .stopped
        case .paused:
            return next == .generating || next == .stopped || next == .failed
        case .completed, .failed, .stopped:
            return false
        }
    }
}

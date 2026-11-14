import Foundation

/// 全局活跃轮次登记表（L2）。
///
/// 语义：`conversationID → 当前活跃轮次的 groupID`。
/// 只记录本进程内**确实在生成**的组，用途：
/// 1. 启动恢复 / 装载后恢复的排除集，避免把正在生成的组修成 `failed`；
/// 2. 跨页面（含新订阅页面）判断"本会话是否有活跃轮次"。
///
/// 一个会话同时只允许一个 open 组（编排器前置检查保证），因此每会话单值即可。
/// `@unchecked Sendable` 依据：全部可变状态由 `NSLock` 保护。
final class ActiveTurnRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var groups: [String: String] = [:]

    func begin(conversationID: String, groupID: String) {
        lock.lock()
        groups[conversationID] = groupID
        lock.unlock()
    }

    /// 只注销自己登记的组：旧轮次收尾不得清掉新轮次的登记。
    func end(conversationID: String, groupID: String) {
        lock.lock()
        if groups[conversationID] == groupID {
            groups.removeValue(forKey: conversationID)
        }
        lock.unlock()
    }

    func activeGroupID(for conversationID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return groups[conversationID]
    }

    func hasActiveTurn(for conversationID: String) -> Bool {
        activeGroupID(for: conversationID) != nil
    }
}

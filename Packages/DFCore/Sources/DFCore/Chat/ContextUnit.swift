import Foundation

/// 上下文组装的最小单元：一个消息组，或一条无组的历史消息（虚拟组）。
public struct ContextUnit: Hashable, Sendable {
    /// `nil` 表示虚拟组：历史消息没有 `group_id`，每条自成一组。
    public var group: MessageGroup?
    /// 组内消息，已按时间升序。
    /// A1 阶段 `Message` 尚无 `seqInGroup`，顺序以 `createdAt` 为准；
    /// A2 引入该字段后，同一毫秒内可按 `seq_in_group` 兜底。
    public var messages: [Message]

    public init(group: MessageGroup? = nil, messages: [Message]) {
        self.group = group
        self.messages = messages
    }

    /// 虚拟组（单条历史消息）
    public static func virtual(_ message: Message) -> ContextUnit {
        ContextUnit(group: nil, messages: [message])
    }
}

/// "取最近 N 个组"的能力声明。
/// A1 只定义协议；A2 用 SQLite 仓储实现，App 层不直接实现。
public protocol ContextUnitProviding: Sendable {
    /// 按时间升序返回最近 `limitGroups` 个组（含当前 `open` 组）。
    func recentUnits(conversationID: String, limitGroups: Int) async throws -> [ContextUnit]
}

import Foundation

/// 上下文组装：把消息组裁剪成模型可用的历史轮次。
///
/// 核心约束（r2.2.1）：
/// - **以完整消息组为边界**裁剪，绝不留下"有 user 无 assistant"或反之的半轮；
/// - 从最新一组向前累加，预算不足时只丢弃更旧的整组，保证历史连续；
/// - 无 `group_id` 的历史消息按虚拟组（每条一组）处理；
/// - 输出白名单 `allowedMessageIDs`，供引用校验使用。
public enum ContextComposer {
    public struct Result: Sendable, Equatable {
        /// 按时间升序的模型历史
        public var turns: [ChatTurn]
        /// 实际进入 `turns` 的消息 id，即引用白名单
        public var allowedMessageIDs: Set<String>
        /// 因预算被丢弃的组数
        public var droppedGroups: Int
        /// 因预算被丢弃的消息数
        public var droppedMessages: Int
        /// 被排除的已软删消息数
        public var excludedDeleted: Int
        /// 被排除的失败 / 取消 / 撤回消息数
        public var excludedFailed: Int
        /// 被排除的空文本消息数
        public var excludedEmpty: Int
        /// 被排除的未完成消息数（draft / sending，不应进入历史）
        public var excludedIncomplete: Int

        public init(
            turns: [ChatTurn] = [],
            allowedMessageIDs: Set<String> = [],
            droppedGroups: Int = 0,
            droppedMessages: Int = 0,
            excludedDeleted: Int = 0,
            excludedFailed: Int = 0,
            excludedEmpty: Int = 0,
            excludedIncomplete: Int = 0
        ) {
            self.turns = turns
            self.allowedMessageIDs = allowedMessageIDs
            self.droppedGroups = droppedGroups
            self.droppedMessages = droppedMessages
            self.excludedDeleted = excludedDeleted
            self.excludedFailed = excludedFailed
            self.excludedEmpty = excludedEmpty
            self.excludedIncomplete = excludedIncomplete
        }
    }

    /// 组装上下文。
    /// - Parameters:
    ///   - units: 按时间升序的组（含当前 open 组）
    ///   - budget: 提示词预算，其中 `historyRatio × totalTokens` 为历史上限
    public static func compose(units: [ContextUnit], budget: PromptBudget) -> Result {
        var result = Result()

        let ratio = min(max(budget.historyRatio, 0), 1)
        let historyBudget = Int(Double(max(budget.totalTokens, 0)) * ratio)

        // 从新到旧累加：一旦超预算就停止，保证丢弃只发生在最旧端、历史连续
        var kept: [(turns: [ChatTurn], ids: [String])] = []
        var used = 0
        var stopped = false

        for unit in units.reversed() {
            let built = makeTurns(for: unit, result: &result)
            // 整组无可用消息：不进入上下文，也不计入 droppedGroups（本就不该出现）
            guard !built.turns.isEmpty else { continue }

            if stopped {
                result.droppedGroups += 1
                result.droppedMessages += built.turns.count
                continue
            }

            // 与 PromptComposer 的成本口径对齐（每条额外 4 token 的角色开销），
            // 否则本层"刚好放下"的内容会在下游被逐条二次裁剪，破坏组边界
            let cost = built.turns.reduce(0) {
                $0 + PromptComposer.estimateTokens($1.text) + 4
            }
            // 最新一组无条件保留，避免极小预算下上下文为空
            if !kept.isEmpty && used + cost > historyBudget {
                stopped = true
                result.droppedGroups += 1
                result.droppedMessages += built.turns.count
                continue
            }

            kept.append(built)
            used += cost
        }

        for entry in kept.reversed() {
            result.turns.append(contentsOf: entry.turns)
            result.allowedMessageIDs.formUnion(entry.ids)
        }
        return result
    }

    // MARK: - 单组转换

    private static func makeTurns(for unit: ContextUnit,
                                  result: inout Result) -> (turns: [ChatTurn], ids: [String]) {
        var turns: [ChatTurn] = []
        var ids: [String] = []
        turns.reserveCapacity(unit.messages.count)

        for message in unit.messages {
            // 软删记录永不出现在上下文中，但保留在库里
            if message.deletedAt != nil {
                result.excludedDeleted += 1
                continue
            }

            switch message.status {
            case .failed, .canceled, .recalled:
                result.excludedFailed += 1
                continue
            case .draft, .sending:
                result.excludedIncomplete += 1
                continue
            case .sent:
                break
            }

            let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                result.excludedEmpty += 1
                continue
            }

            let role: ChatTurnRole
            switch message.role {
            case .user:
                role = .user
            case .assistant:
                role = .assistant
            case .system:
                role = .system
            case .event:
                // 事件消息不进入对话历史
                continue
            }

            turns.append(ChatTurn(role: role, text: message.text))
            ids.append(message.id)
        }
        return (turns, ids)
    }
}

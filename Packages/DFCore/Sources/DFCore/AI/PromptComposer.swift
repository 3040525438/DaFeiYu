import Foundation

/// Token 预算配置。比例之和可以大于 1，各段独立限流，核心人格永不被裁剪。
public struct PromptBudget: Sendable {
    public var totalTokens: Int
    public var coreRatio: Double
    public var memoryRatio: Double
    public var historyRatio: Double

    public init(
        totalTokens: Int = 6000,
        coreRatio: Double = 0.15,
        memoryRatio: Double = 0.35,
        historyRatio: Double = 0.30
    ) {
        self.totalTokens = totalTokens
        self.coreRatio = coreRatio
        self.memoryRatio = memoryRatio
        self.historyRatio = historyRatio
    }
}

public struct PromptInput: Sendable {
    public var corePersona: String
    public var rules: String
    public var outerPersona: String
    public var currentState: String
    /// 已由调用方按 salience × recency × relevance 排序
    public var memories: [String]
    public var history: [ChatTurn]

    public init(
        corePersona: String,
        rules: String = "",
        outerPersona: String = "",
        currentState: String = "",
        memories: [String] = [],
        history: [ChatTurn] = []
    ) {
        self.corePersona = corePersona
        self.rules = rules
        self.outerPersona = outerPersona
        self.currentState = currentState
        self.memories = memories
        self.history = history
    }
}

public struct ComposedPrompt: Sendable {
    public var system: String
    public var messages: [ChatTurn]
    public var droppedMemoryCount: Int
    public var droppedHistoryCount: Int
    public var estimatedTokens: Int
    /// 核心人格本身已超出预算（不会被裁剪，但需要提示用户精简）
    public var coreOverBudget: Bool
}

public enum PromptComposer {
    public static let defaultRules = """
    你在和用户一对一聊天，是长期陪伴的角色，不是通用助手，不要自称 AI。
    - 允许有独立判断：可以不同意、可以反驳，但要给出理由。
    - 不编造没有发生过的事；不确定就说不确定，或者直接问。
    - 不执行任何系统操作，不涉及付费，不泄露用户隐私。
    - 回复自然、口语化，避免机械问候和重复句式。
    """

    /// 保守估算：中文约 2 字 ≈ 1 token。仅用于预算裁剪，不用于计费。
    public static func estimateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, (text.count + 1) / 2)
    }

    public static func compose(_ input: PromptInput, budget: PromptBudget = PromptBudget()) -> ComposedPrompt {
        var sections: [String] = []

        func appendSection(_ title: String, _ body: String) -> Int {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return 0 }
            let block = "【\(title)】\n\(trimmed)"
            sections.append(block)
            return estimateTokens(block)
        }

        // L0 核心人格：不裁剪
        let coreTokens = appendSection("核心人格", input.corePersona)

        // L1 行为准则
        _ = appendSection("行为准则", input.rules.isEmpty ? defaultRules : input.rules)

        // L2 外围人格与成长
        _ = appendSection("外围人格与成长", input.outerPersona)

        // L3 当前状态
        _ = appendSection("当前状态", input.currentState)

        // L4 记忆：按给定顺序填充，超出预算则丢弃尾部（低分记忆）
        let memoryCap = Int(Double(budget.totalTokens) * budget.memoryRatio)
        var memoryLines: [String] = []
        var memoryTokens = 0
        var droppedMemory = 0
        for memory in input.memories {
            let line = "- " + memory
            let cost = estimateTokens(line)
            if memoryTokens + cost <= memoryCap {
                memoryLines.append(line)
                memoryTokens += cost
            } else {
                droppedMemory += 1
            }
        }
        if !memoryLines.isEmpty {
            _ = appendSection("相关记忆", memoryLines.joined(separator: "\n"))
        }

        // L5 历史：从最新往前取，预算用完即止，最后翻回升序
        let historyCap = Int(Double(budget.totalTokens) * budget.historyRatio)
        var keptReversed: [ChatTurn] = []
        var historyTokens = 0
        var droppedHistory = 0
        for turn in input.history.reversed() {
            let cost = estimateTokens(turn.text) + 4
            if historyTokens + cost <= historyCap {
                keptReversed.append(turn)
                historyTokens += cost
            } else {
                droppedHistory += 1
            }
        }
        let orderedHistory = Array(keptReversed.reversed())

        let system = sections.joined(separator: "\n\n")
        let total = estimateTokens(system)
            + orderedHistory.reduce(0) { $0 + estimateTokens($1.text) + 4 }

        return ComposedPrompt(
            system: system,
            messages: orderedHistory,
            droppedMemoryCount: droppedMemory,
            droppedHistoryCount: droppedHistory,
            estimatedTokens: total,
            coreOverBudget: coreTokens > Int(Double(budget.totalTokens) * budget.coreRatio)
        )
    }
}

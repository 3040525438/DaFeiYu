import Foundation

// MARK: - D10 成本口径与预算

/// 费用口径：明确区分"已确认 / 估算 / 无法计量"，禁止把未知费用当成 0。
public enum CostKind: String, Codable, Sendable, CaseIterable {
    /// 服务端返回真实用量，且配置了单价
    case confirmed
    /// 用量或单价有一项缺失，按可解释的规则估算
    case estimated
    /// 既没有用量也没有单价，成本未知（记账为 NULL，不记 0）
    case unavailable
}

/// 费用发生场景：普通聊天 / 自主行动
public enum BudgetScope: String, Codable, Sendable, CaseIterable {
    case chat
    case autonomy
}

/// 模型单价（人民币 / 千 token）。
public struct ModelPricing: Codable, Sendable, Equatable {
    public var inputPerThousandYuan: Double
    public var outputPerThousandYuan: Double
    public var currency: String

    public init(
        inputPerThousandYuan: Double,
        outputPerThousandYuan: Double,
        currency: String = "CNY"
    ) {
        self.inputPerThousandYuan = inputPerThousandYuan
        self.outputPerThousandYuan = outputPerThousandYuan
        self.currency = currency
    }

    /// 单价是否可用（非负；0 表示免费模型，例如本地推理）
    public var isUsable: Bool {
        inputPerThousandYuan >= 0 && outputPerThousandYuan >= 0
    }

    public func cost(promptTokens: Int, completionTokens: Int) -> Double {
        let input = Double(max(0, promptTokens)) / 1000 * inputPerThousandYuan
        let output = Double(max(0, completionTokens)) / 1000 * outputPerThousandYuan
        return input + output
    }

    /// 按上限预估一次调用（用于调用前预占，宁可略高也不低估）
    public func estimatedCost(
        promptTokens: Int,
        maxCompletionTokens: Int
    ) -> Double {
        cost(promptTokens: promptTokens, completionTokens: maxCompletionTokens)
    }
}

/// token 估算（仅在服务端未返回 usage 时使用，结果标记为"估算"）。
public enum TokenEstimator {
    /// 中日韩字符按 1 字 ≈ 1 token，其余按 4 字符 ≈ 1 token。
    public static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if (0x2E80...0x9FFF).contains(scalar.value)
                || (0xAC00...0xD7AF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value) {
                cjk += 1
            } else {
                other += 1
            }
        }
        return cjk + (other + 3) / 4
    }

    /// 估算整轮请求的输入 token（含每条消息的少量结构开销）。
    public static func estimate(system: String, turns: [ChatTurn]) -> Int {
        var total = estimate(system) + 8
        for turn in turns {
            total += estimate(turn.text) + 4
        }
        return total
    }
}

/// 预算上限。nil 表示不限制；0 表示不允许任何花费。
public struct BudgetLimits: Codable, Sendable, Equatable {
    /// 每日总预算（聊天 + 自主行动）
    public var dailyYuan: Double?
    /// 单次调用预算
    public var perCallYuan: Double?
    /// 自主行动每日预算
    public var autonomyDailyYuan: Double?
    /// 每条"无法计量"的记录，按此保守值计入已花费用
    public var unknownReserveYuan: Double

    public static let `default` = BudgetLimits(
        dailyYuan: nil,
        perCallYuan: nil,
        autonomyDailyYuan: nil,
        unknownReserveYuan: 0.02
    )

    public init(
        dailyYuan: Double? = nil,
        perCallYuan: Double? = nil,
        autonomyDailyYuan: Double? = nil,
        unknownReserveYuan: Double = 0.02
    ) {
        self.dailyYuan = dailyYuan
        self.perCallYuan = perCallYuan
        self.autonomyDailyYuan = autonomyDailyYuan
        self.unknownReserveYuan = unknownReserveYuan
    }

    public func normalized() -> BudgetLimits {
        var copy = self
        copy.dailyYuan = copy.dailyYuan.map { max(0, $0) }
        copy.perCallYuan = copy.perCallYuan.map { max(0, $0) }
        copy.autonomyDailyYuan = copy.autonomyDailyYuan.map { max(0, $0) }
        copy.unknownReserveYuan = min(max(0, copy.unknownReserveYuan), 100)
        return copy
    }
}

/// 当日花费快照（按口径分开，不合并成"一个数"）。
public struct BudgetSpend: Sendable, Equatable {
    public var confirmedYuan: Double
    public var estimatedYuan: Double
    /// 无法计量的调用条数（成本未知，不能当 0）
    public var unknownCount: Int
    /// 自主行动部分（confirmed + estimated）
    public var autonomyYuan: Double
    /// 自主行动里无法计量的条数
    public var autonomyUnknownCount: Int

    public static let zero = BudgetSpend(
        confirmedYuan: 0,
        estimatedYuan: 0,
        unknownCount: 0,
        autonomyYuan: 0,
        autonomyUnknownCount: 0
    )

    public init(
        confirmedYuan: Double,
        estimatedYuan: Double,
        unknownCount: Int,
        autonomyYuan: Double,
        autonomyUnknownCount: Int = 0
    ) {
        self.confirmedYuan = confirmedYuan
        self.estimatedYuan = estimatedYuan
        self.unknownCount = unknownCount
        self.autonomyYuan = autonomyYuan
        self.autonomyUnknownCount = autonomyUnknownCount
    }

    /// 已知口径合计（不含未知）
    public var knownTotalYuan: Double {
        confirmedYuan + estimatedYuan
    }

    /// 用于预算判定的保守花费：未知条目按配置的保守单价计入。
    public func effectiveYuan(unknownReserveYuan: Double) -> Double {
        let reserve = max(0, unknownReserveYuan)
        return knownTotalYuan + Double(max(0, unknownCount)) * reserve
    }

    public func effectiveAutonomyYuan(unknownReserveYuan: Double) -> Double {
        let reserve = max(0, unknownReserveYuan)
        return autonomyYuan + Double(max(0, autonomyUnknownCount)) * reserve
    }
}

/// 预算判定结果。
public struct BudgetDecision: Sendable, Equatable {
    public var allowed: Bool
    public var reason: String?
    /// 保守口径的已花费用
    public var effectiveSpendYuan: Double
    /// 允许时的剩余额度；不限额时为 nil
    public var remainingYuan: Double?

    public init(
        allowed: Bool,
        reason: String?,
        effectiveSpendYuan: Double,
        remainingYuan: Double?
    ) {
        self.allowed = allowed
        self.reason = reason
        self.effectiveSpendYuan = effectiveSpendYuan
        self.remainingYuan = remainingYuan
    }

    public static func allow(
        effectiveSpendYuan: Double,
        remainingYuan: Double?
    ) -> BudgetDecision {
        BudgetDecision(
            allowed: true,
            reason: nil,
            effectiveSpendYuan: effectiveSpendYuan,
            remainingYuan: remainingYuan
        )
    }

    public static func blocked(
        _ reason: String,
        effectiveSpendYuan: Double
    ) -> BudgetDecision {
        BudgetDecision(
            allowed: false,
            reason: reason,
            effectiveSpendYuan: effectiveSpendYuan,
            remainingYuan: nil
        )
    }
}

/// 预算闸门（纯函数）：单次上限 → 每日总预算 → 自主行动预算。
public enum BudgetGuard {
    public static func evaluate(
        limits: BudgetLimits,
        spend: BudgetSpend,
        scope: BudgetScope,
        estimatedNextCallYuan: Double
    ) -> BudgetDecision {
        let limits = limits.normalized()
        let estimated = max(0, estimatedNextCallYuan)
        let effective = spend.effectiveYuan(unknownReserveYuan: limits.unknownReserveYuan)

        if let perCall = limits.perCallYuan, estimated > perCall {
            return .blocked(
                String(
                    format: "单次调用预计 %.2f 元，超过单次上限 %.2f 元",
                    estimated,
                    perCall
                ),
                effectiveSpendYuan: effective
            )
        }

        if let daily = limits.dailyYuan {
            if effective + estimated > daily {
                return .blocked(
                    String(
                        format: "今日已花 %.2f 元（含未知费用保守估算），本次预计 %.2f 元，超过每日预算 %.2f 元",
                        effective,
                        estimated,
                        daily
                    ),
                    effectiveSpendYuan: effective
                )
            }
        }

        if scope == .autonomy, let autonomyLimit = limits.autonomyDailyYuan {
            let autonomySpend = spend.effectiveAutonomyYuan(
                unknownReserveYuan: limits.unknownReserveYuan
            )
            if autonomySpend + estimated > autonomyLimit {
                return .blocked(
                    String(
                        format: "自主行动今日已花 %.2f 元，本次预计 %.2f 元，超过自主预算 %.2f 元",
                        autonomySpend,
                        estimated,
                        autonomyLimit
                    ),
                    effectiveSpendYuan: effective
                )
            }
        }

        let remaining: Double?
        if let daily = limits.dailyYuan {
            remaining = max(0, daily - effective - estimated)
        } else {
            remaining = nil
        }
        return .allow(effectiveSpendYuan: effective, remainingYuan: remaining)
    }
}

/// 供 AutonomyGate 使用的预算上下文。
public struct AutonomyBudgetContext: Sendable, Equatable {
    public var limits: BudgetLimits
    public var spend: BudgetSpend
    /// 本次主动生成预计花费（元）
    public var estimatedNextCallYuan: Double

    public init(limits: BudgetLimits, spend: BudgetSpend, estimatedNextCallYuan: Double) {
        self.limits = limits
        self.spend = spend
        self.estimatedNextCallYuan = estimatedNextCallYuan
    }
}

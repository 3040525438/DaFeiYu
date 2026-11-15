import XCTest
@testable import DFCore

/// D10：预算判定纯函数（边界 / 口径 / 未知费用不当 0）
final class BudgetTests: XCTestCase {
    // MARK: - 估算与单价

    func testTokenEstimatorHandlesCJKAndLatin() {
        XCTAssertEqual(TokenEstimator.estimate("你好世界"), 4)
        XCTAssertEqual(TokenEstimator.estimate("abcdefgh"), 2)
        XCTAssertEqual(TokenEstimator.estimate("你好abcd"), 3)
        XCTAssertEqual(TokenEstimator.estimate(""), 0)

        let turns = [ChatTurn(role: .user, text: "你好"), ChatTurn(role: .assistant, text: "在的")]
        // 8 固定 + (2 + 4) + (2 + 4)
        XCTAssertEqual(TokenEstimator.estimate(system: "", turns: turns), 20)
    }

    func testPricingCostsByThousandTokens() {
        let pricing = ModelPricing(inputPerThousandYuan: 2, outputPerThousandYuan: 8)
        let cost = pricing.cost(promptTokens: 1500, completionTokens: 500)
        XCTAssertEqual(cost, 3.0 + 4.0, accuracy: 0.0001)
        XCTAssertEqual(pricing.cost(promptTokens: -10, completionTokens: -10), 0)
        XCTAssertTrue(ModelPricing(inputPerThousandYuan: 0, outputPerThousandYuan: 0).isUsable)
        XCTAssertFalse(ModelPricing(inputPerThousandYuan: -1, outputPerThousandYuan: 1).isUsable)
    }

    // MARK: - 单次上限

    func testPerCallLimitBoundary() {
        let limits = BudgetLimits(perCallYuan: 0.5)
        let spend = BudgetSpend.zero

        let equal = BudgetGuard.evaluate(
            limits: limits,
            spend: spend,
            scope: .chat,
            estimatedNextCallYuan: 0.5
        )
        XCTAssertTrue(equal.allowed, "刚好等于单次上限应放行")

        let over = BudgetGuard.evaluate(
            limits: limits,
            spend: spend,
            scope: .chat,
            estimatedNextCallYuan: 0.51
        )
        XCTAssertFalse(over.allowed)
        XCTAssertTrue(over.reason?.contains("单次上限") == true)
    }

    // MARK: - 每日预算

    func testDailyBudgetBoundary() {
        let limits = BudgetLimits(dailyYuan: 1.0)
        let spend = BudgetSpend(
            confirmedYuan: 0.6,
            estimatedYuan: 0.2,
            unknownCount: 0,
            autonomyYuan: 0
        )

        let equal = BudgetGuard.evaluate(
            limits: limits,
            spend: spend,
            scope: .chat,
            estimatedNextCallYuan: 0.2
        )
        XCTAssertTrue(equal.allowed, "已花 0.8 + 本次 0.2 = 1.0，刚好等于预算应放行")
        XCTAssertEqual(equal.remainingYuan, 0, accuracy: 0.0001)

        let over = BudgetGuard.evaluate(
            limits: limits,
            spend: spend,
            scope: .chat,
            estimatedNextCallYuan: 0.21
        )
        XCTAssertFalse(over.allowed)
        XCTAssertTrue(over.reason?.contains("每日预算") == true)
    }

    func testZeroDailyBudgetBlocksAnyPaidCall() {
        let limits = BudgetLimits(dailyYuan: 0)
        let blocked = BudgetGuard.evaluate(
            limits: limits,
            spend: .zero,
            scope: .chat,
            estimatedNextCallYuan: 0.01
        )
        XCTAssertFalse(blocked.allowed)

        let free = BudgetGuard.evaluate(
            limits: limits,
            spend: .zero,
            scope: .chat,
            estimatedNextCallYuan: 0
        )
        XCTAssertTrue(free.allowed, "零成本（本地模型）不受每日预算影响")
    }

    // MARK: - 未知费用不得当 0

    func testUnknownCostIsReservedNotEmpty() {
        let limits = BudgetLimits(dailyYuan: 1.0, unknownReserveYuan: 0.5)
        let spend = BudgetSpend(
            confirmedYuan: 0,
            estimatedYuan: 0,
            unknownCount: 2,
            autonomyYuan: 0
        )

        XCTAssertEqual(spend.effectiveYuan(unknownReserveYuan: 0.5), 1.0, accuracy: 0.0001)

        let blocked = BudgetGuard.evaluate(
            limits: limits,
            spend: spend,
            scope: .chat,
            estimatedNextCallYuan: 0.01
        )
        XCTAssertFalse(blocked.allowed, "两条未知调用应被保守计入，不能当成 0")

        let zeroReserve = BudgetGuard.evaluate(
            limits: BudgetLimits(dailyYuan: 1.0, unknownReserveYuan: 0),
            spend: spend,
            scope: .chat,
            estimatedNextCallYuan: 1.0
        )
        XCTAssertTrue(zeroReserve.allowed)
    }

    // MARK: - 自主行动预算

    func testAutonomyBudgetAppliesOnlyToAutonomyScope() {
        let limits = BudgetLimits(dailyYuan: 10, autonomyDailyYuan: 0.3)
        let spend = BudgetSpend(
            confirmedYuan: 1.0,
            estimatedYuan: 0,
            unknownCount: 0,
            autonomyYuan: 0.25
        )
        let estimated = 0.1

        let autonomy = BudgetGuard.evaluate(
            limits: limits,
            spend: spend,
            scope: .autonomy,
            estimatedNextCallYuan: estimated
        )
        XCTAssertFalse(autonomy.allowed)
        XCTAssertTrue(autonomy.reason?.contains("自主预算") == true)

        let chat = BudgetGuard.evaluate(
            limits: limits,
            spend: spend,
            scope: .chat,
            estimatedNextCallYuan: estimated
        )
        XCTAssertTrue(chat.allowed, "聊天不受自主行动预算限制")
    }

    func testAutonomyUnknownIsReserved() {
        let limits = BudgetLimits(autonomyDailyYuan: 0.5, unknownReserveYuan: 0.3)
        let spend = BudgetSpend(
            confirmedYuan: 0,
            estimatedYuan: 0,
            unknownCount: 1,
            autonomyYuan: 0,
            autonomyUnknownCount: 1
        )
        XCTAssertEqual(
            spend.effectiveAutonomyYuan(unknownReserveYuan: 0.3),
            0.3,
            accuracy: 0.0001
        )
        let blocked = BudgetGuard.evaluate(
            limits: limits,
            spend: spend,
            scope: .autonomy,
            estimatedNextCallYuan: 0.3
        )
        XCTAssertFalse(blocked.allowed)
    }

    // MARK: - 配置归一

    func testLimitsAreNormalized() {
        let limits = BudgetLimits(
            dailyYuan: -5,
            perCallYuan: -1,
            autonomyDailyYuan: -2,
            unknownReserveYuan: -3
        ).normalized()
        XCTAssertEqual(limits.dailyYuan, 0)
        XCTAssertEqual(limits.perCallYuan, 0)
        XCTAssertEqual(limits.autonomyDailyYuan, 0)
        XCTAssertEqual(limits.unknownReserveYuan, 0)
    }

    func testUnlimitedByDefault() {
        let decision = BudgetGuard.evaluate(
            limits: .default,
            spend: .zero,
            scope: .autonomy,
            estimatedNextCallYuan: 100
        )
        XCTAssertTrue(decision.allowed)
        XCTAssertNil(decision.remainingYuan)
    }

    // MARK: - 闸门接线（D10）

    func testGateBlocksEveryTriggerWhenBudgetExhausted() {
        let budget = AutonomyBudgetContext(
            limits: BudgetLimits(dailyYuan: 0.5),
            spend: BudgetSpend(
                confirmedYuan: 0.5,
                estimatedYuan: 0,
                unknownCount: 0,
                autonomyYuan: 0.5
            ),
            estimatedNextCallYuan: 0.01
        )
        for trigger in ProactiveTrigger.allCases {
            let decision = AutonomyGate.evaluate(
                policy: .default,
                trigger: trigger,
                nowMillis: 1_000_000,
                nowMinuteOfDay: 12 * 60,
                lastSentAt: nil,
                todaySentCount: 0,
                budget: budget
            )
            XCTAssertFalse(decision.allowed, "\(trigger) 也会花模型费，必须被预算拦截")
            XCTAssertTrue(decision.reason?.contains("预算") == true)
        }
    }

    func testGateAllowsWithinBudget() {
        let budget = AutonomyBudgetContext(
            limits: BudgetLimits(dailyYuan: 1.0, autonomyDailyYuan: 0.5),
            spend: BudgetSpend(
                confirmedYuan: 0.2,
                estimatedYuan: 0.1,
                unknownCount: 0,
                autonomyYuan: 0.3
            ),
            estimatedNextCallYuan: 0.1
        )
        let decision = AutonomyGate.evaluate(
            policy: .default,
            trigger: .memoryConsolidation,
            nowMillis: 1_000_000,
            nowMinuteOfDay: 3 * 60,
            lastSentAt: nil,
            todaySentCount: 99,
            budget: budget
        )
        XCTAssertTrue(decision.allowed)
    }

    func testLegacyDailyBudgetUsesEffectiveAutonomySpend() {
        var policy = AutonomyPolicy.default
        policy.dailyBudgetYuan = 0.05
        let budget = AutonomyBudgetContext(
            limits: BudgetLimits(unknownReserveYuan: 0.05),
            spend: BudgetSpend(
                confirmedYuan: 0,
                estimatedYuan: 0,
                unknownCount: 1,
                autonomyYuan: 0,
                autonomyUnknownCount: 1
            ),
            estimatedNextCallYuan: 0
        )
        let decision = AutonomyGate.evaluate(
            policy: policy,
            trigger: .selfReflection,
            nowMillis: 1_000_000,
            nowMinuteOfDay: 12 * 60,
            lastSentAt: nil,
            todaySentCount: 0,
            budget: budget
        )
        XCTAssertFalse(decision.allowed, "未知自主费用必须按保守单价计入旧预算判定")
        XCTAssertTrue(decision.reason?.contains("自主预算") == true)
    }
}

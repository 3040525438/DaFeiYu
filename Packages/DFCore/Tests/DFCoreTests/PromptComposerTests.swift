import XCTest
@testable import DFCore

final class PromptComposerTests: XCTestCase {
    func testCorePersonaIsNeverDropped() {
        let longCore = String(repeating: "核心人格设定。", count: 200)
        let input = PromptInput(corePersona: longCore, history: [
            ChatTurn(role: .user, text: "你好")
        ])
        let budget = PromptBudget(totalTokens: 100, coreRatio: 0.1, memoryRatio: 0.1, historyRatio: 0.1)
        let result = PromptComposer.compose(input, budget: budget)

        XCTAssertTrue(result.system.contains("核心人格设定"))
        XCTAssertTrue(result.coreOverBudget, "核心人格超出预算时必须被标记，而不是被裁剪")
    }

    func testHistoryKeepsNewestTurns() {
        let history = (1...5).map { index in
            ChatTurn(role: .user, text: "第\(index)条")
        }
        let input = PromptInput(corePersona: "简短人格", history: history)
        let budget = PromptBudget(totalTokens: 100, coreRatio: 0.2, memoryRatio: 0.1, historyRatio: 0.1)
        let result = PromptComposer.compose(input, budget: budget)

        XCTAssertEqual(result.messages.count, 1)
        XCTAssertTrue(result.messages[0].text.contains("第5条"))
        XCTAssertEqual(result.droppedHistoryCount, 4)
    }

    func testHistoryKeepsChronologicalOrder() {
        let history = (1...3).map { index in
            ChatTurn(role: index % 2 == 0 ? .assistant : .user, text: "第\(index)条")
        }
        let input = PromptInput(corePersona: "人格", history: history)
        let result = PromptComposer.compose(input, budget: PromptBudget(totalTokens: 6000))

        XCTAssertEqual(result.messages.map(\.text), ["第1条", "第2条", "第3条"])
    }

    func testMemoryTruncationCountsDroppedItems() {
        let memories = (1...10).map { _ in String(repeating: "很重要的记忆内容", count: 10) }
        let input = PromptInput(corePersona: "人格", memories: memories)
        let budget = PromptBudget(totalTokens: 100, coreRatio: 0.2, memoryRatio: 0.2, historyRatio: 0.1)
        let result = PromptComposer.compose(input, budget: budget)

        XCTAssertEqual(result.droppedMemoryCount, 10)
        XCTAssertFalse(result.system.contains("相关记忆"))
    }

    func testEmptyInputStillProducesRules() {
        let result = PromptComposer.compose(PromptInput(corePersona: ""))
        XCTAssertTrue(result.system.contains("行为准则"))
        XCTAssertTrue(result.messages.isEmpty)
    }

    func testTokenEstimateIsPositiveForNonEmptyText() {
        XCTAssertEqual(PromptComposer.estimateTokens(""), 0)
        XCTAssertGreaterThan(PromptComposer.estimateTokens("一句话"), 0)
    }

    // MARK: - 人格继承（P0）

    func testRelationshipSectionIsInjectedAndNeverTrimmed() {
        let relationship = "对用户的称呼：小鱼干\n关系摘要：从 AstrBot 时代一路走来的老朋友"
        let input = PromptInput(
            corePersona: "人格",
            relationship: relationship,
            history: [ChatTurn(role: .user, text: "你好")]
        )
        // 极小预算下记忆与历史都会被裁掉，关系设定必须原样保留
        let budget = PromptBudget(totalTokens: 50, coreRatio: 0.2, memoryRatio: 0.1, historyRatio: 0.1)
        let result = PromptComposer.compose(input, budget: budget)

        XCTAssertTrue(result.system.contains("【关系设定】"))
        XCTAssertTrue(result.system.contains("小鱼干"))
        XCTAssertTrue(result.system.contains("从 AstrBot 时代一路走来的老朋友"))
    }

    func testEmptyRelationshipOmitsSection() {
        let result = PromptComposer.compose(PromptInput(corePersona: "人格"))
        XCTAssertFalse(result.system.contains("【关系设定】"))
    }

    func testOuterPersonaIsNotBudgetTrimmed() {
        // 用户导入的人格文件不允许被缩减：条目再多也要全量进入 L2 段
        let outer = (1...300).map { "性格特质/第\($0)条：\(String(repeating: "设定内容", count: 5))" }
            .joined(separator: "\n")
        let input = PromptInput(corePersona: "人格", outerPersona: outer)
        let budget = PromptBudget(totalTokens: 100, coreRatio: 0.1, memoryRatio: 0.1, historyRatio: 0.1)
        let result = PromptComposer.compose(input, budget: budget)

        XCTAssertTrue(result.system.contains("第1条"))
        XCTAssertTrue(result.system.contains("第300条"))
    }
}

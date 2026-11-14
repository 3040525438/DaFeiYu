import XCTest
@testable import DFCore

/// A1 · C 系列：上下文按组裁剪、过滤与白名单（纯逻辑，不接触数据库）
final class ContextComposerTests: XCTestCase {

    // MARK: - Helpers

    private func message(
        _ id: String,
        _ role: MessageRole,
        _ text: String,
        status: MessageStatus = .sent,
        at: Int64,
        deleted: Bool = false
    ) -> Message {
        Message(
            id: id,
            conversationID: "c1",
            role: role,
            text: text,
            status: status,
            origin: role == .assistant ? .reply : .user,
            createdAt: at,
            deletedAt: deleted ? at + 1 : nil
        )
    }

    /// 一轮完整问答（2 条）
    private func turn(id: String, at: Int64, text: String = "你好") -> ContextUnit {
        let group = MessageGroup(
            id: "g-\(id)",
            conversationID: "c1",
            turnIndex: Int(at),
            openedAt: at
        )
        return ContextUnit(group: group, messages: [
            message("\(id)-u", .user, text, at: at),
            message("\(id)-a", .assistant, text, at: at + 1)
        ])
    }

    private func budget(total: Int = 1000, ratio: Double = 0.05) -> PromptBudget {
        PromptBudget(totalTokens: total, coreRatio: 0.1, memoryRatio: 0.1, historyRatio: ratio)
    }

    // MARK: - C01 按完整组裁剪

    func testC01_DropsWholeGroupsOnly() {
        // 6 组 × 2 条，每组成本 10 token；预算 50 → 保留最新 5 组
        let units = (1...6).map { turn(id: "\($0)", at: Int64($0) * 10) }
        let result = ContextComposer.compose(units: units, budget: budget())

        XCTAssertEqual(result.droppedGroups, 1)
        XCTAssertEqual(result.droppedMessages, 2, "丢弃的是一整组，不是半轮")
        XCTAssertEqual(result.turns.count, 10)

        // 结果必须是成对的 user / assistant，首条不得是孤立 assistant
        XCTAssertEqual(result.turns.first?.role, .user)
        for index in stride(from: 0, to: result.turns.count, by: 2) {
            XCTAssertEqual(result.turns[index].role, .user)
            XCTAssertEqual(result.turns[index + 1].role, .assistant)
        }
    }

    // MARK: - C02 软删排除

    func testC02_ExcludesDeletedMessages() {
        let group = MessageGroup(id: "g1", conversationID: "c1", turnIndex: 1, openedAt: 1)
        let unit = ContextUnit(group: group, messages: [
            message("u1", .user, "在吗", at: 1),
            message("a1", .assistant, "在的", at: 2, deleted: true),
            message("a2", .assistant, "怎么了", at: 3)
        ])
        let result = ContextComposer.compose(units: [unit], budget: budget())

        XCTAssertEqual(result.excludedDeleted, 1)
        XCTAssertEqual(result.turns.count, 2)
        XCTAssertFalse(result.allowedMessageIDs.contains("a1"))
    }

    // MARK: - C03 失败 / 取消 / 撤回排除

    func testC03_ExcludesFailedCanceledRecalled() {
        let group = MessageGroup(id: "g1", conversationID: "c1", turnIndex: 1, openedAt: 1)
        let unit = ContextUnit(group: group, messages: [
            message("u1", .user, "问题", at: 1),
            message("a1", .assistant, "半截回答", status: .failed, at: 2),
            message("a2", .assistant, "被取消的回答", status: .canceled, at: 3),
            message("u2", .user, "被撤回的问题", status: .recalled, at: 4)
        ])
        let result = ContextComposer.compose(units: [unit], budget: budget())

        XCTAssertEqual(result.excludedFailed, 3)
        XCTAssertEqual(result.turns.count, 1)
        XCTAssertEqual(result.turns.first?.text, "问题")
    }

    // MARK: - C04 空文本排除

    func testC04_ExcludesBlankText() {
        let group = MessageGroup(id: "g1", conversationID: "c1", turnIndex: 1, openedAt: 1)
        let unit = ContextUnit(group: group, messages: [
            message("u1", .user, "有效内容", at: 1),
            message("a1", .assistant, "   \n ", at: 2)
        ])
        let result = ContextComposer.compose(units: [unit], budget: budget())

        XCTAssertEqual(result.excludedEmpty, 1)
        XCTAssertEqual(result.turns.count, 1)
    }

    // MARK: - C05 无组历史按虚拟组处理

    func testC05_VirtualUnitsKeepOrder() {
        let units = [
            ContextUnit.virtual(message("m1", .user, "第一句", at: 1)),
            ContextUnit.virtual(message("m2", .assistant, "第二句", at: 2)),
            ContextUnit.virtual(message("m3", .user, "第三句", at: 3))
        ]
        let result = ContextComposer.compose(units: units, budget: budget())

        XCTAssertEqual(result.turns.map(\.text), ["第一句", "第二句", "第三句"])
        XCTAssertEqual(result.droppedGroups, 0)
    }

    // MARK: - C06 极小预算仍保留最近一组

    func testC06_KeepsAtLeastLastGroup() {
        let units = (1...3).map { turn(id: "\($0)", at: Int64($0) * 10) }
        let result = ContextComposer.compose(units: units, budget: budget(total: 10, ratio: 0.1))

        XCTAssertEqual(result.turns.count, 2, "最近一组必须完整保留")
        XCTAssertEqual(result.turns.map(\.role), [.user, .assistant])
        XCTAssertEqual(result.droppedGroups, 2)
    }

    // MARK: - C07 顺序稳定

    func testC07_DeterministicOrder() {
        let units = (1...4).map { turn(id: "\($0)", at: Int64($0) * 10) }
        let first = ContextComposer.compose(units: units, budget: budget())
        let second = ContextComposer.compose(units: units, budget: budget())
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.turns.map(\.text), Array(repeating: "你好", count: first.turns.count))
    }

    // MARK: - C08 白名单输出

    func testC08_AllowedIDsMatchTurns() {
        let units = (1...3).map { turn(id: "\($0)", at: Int64($0) * 10) }
        let result = ContextComposer.compose(units: units, budget: budget())

        let expected: Set<String> = Set(units.flatMap { $0.messages.map(\.id) })
        XCTAssertEqual(result.allowedMessageIDs, expected)
        XCTAssertEqual(result.allowedMessageIDs.count, result.turns.count)
    }
}

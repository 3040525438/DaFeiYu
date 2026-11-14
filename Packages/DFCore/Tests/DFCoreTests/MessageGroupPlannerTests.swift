import XCTest
@testable import DFCore

/// A1 · G 系列：消息组规划的纯逻辑断言（不接触数据库）
final class MessageGroupPlannerTests: XCTestCase {

    // MARK: - G01 连续计算下一组编号

    func testG01_NextTurnIndexIsContiguous() {
        XCTAssertEqual(GroupPlanner.nextTurnIndex(after: nil), 1, "无组时从 1 开始")
        XCTAssertEqual(GroupPlanner.nextTurnIndex(after: 1), 2)
        XCTAssertEqual(GroupPlanner.nextTurnIndex(after: 5), 6)
        // 异常入参不得产生非正数
        XCTAssertEqual(GroupPlanner.nextTurnIndex(after: 0), 1)
        XCTAssertEqual(GroupPlanner.nextTurnIndex(after: -3), 1)
        // 饱和策略：不得溢出崩溃
        XCTAssertEqual(GroupPlanner.nextTurnIndex(after: Int.max), Int.max)
    }

    // MARK: - G02 连续计算组内 seq

    func testG02_NextSeqStartsAtZeroAndIsContiguous() {
        XCTAssertEqual(GroupPlanner.nextSeq(afterMaxExisting: nil), 0, "首条消息 seq 为 0")
        XCTAssertEqual(GroupPlanner.nextSeq(afterMaxExisting: 0), 1)
        XCTAssertEqual(GroupPlanner.nextSeq(afterMaxExisting: 3), 4)
        XCTAssertEqual(GroupPlanner.nextSeq(afterMaxExisting: -1), 0, "异常入参回到 0")
        XCTAssertEqual(GroupPlanner.nextSeq(afterMaxExisting: Int.max), Int.max, "饱和策略")
    }

    func testG02_NextSeqUsesMaxNotCount() {
        // 组内 seq 为 0/1/2，其中 seq=1 已被软删：max 仍是 2 → 下一条为 3
        // 若按"有效条数(2)"计算会得到 2，与既有行冲突
        XCTAssertEqual(GroupPlanner.nextSeq(afterMaxExisting: 2), 3)
    }

    // MARK: - G03 状态转移与编号协同

    func testG03_CanTransitionMatrix() {
        for to in MessageGroupStatus.allCases where to != .open {
            XCTAssertTrue(GroupPlanner.canTransition(.open, to: to), "open 应可转到 \(to)")
        }
        XCTAssertFalse(GroupPlanner.canTransition(.open, to: .open), "open 不能重复转移")

        for from in [MessageGroupStatus.complete, .failed, .aborted] {
            for to in MessageGroupStatus.allCases {
                XCTAssertFalse(GroupPlanner.canTransition(from, to: to),
                               "终态 \(from) 不得转到 \(to)")
            }
        }
    }

    func testG03_NextTurnIndexStillIncrementsAfterClose() {
        var maxTurn: Int? = nil
        var assigned: [Int] = []
        for _ in 0..<3 {
            let turn = GroupPlanner.nextTurnIndex(after: maxTurn)
            assigned.append(turn)
            maxTurn = turn
        }
        XCTAssertEqual(assigned, [1, 2, 3], "关组后再次开组仍应连续递增")
    }

    // MARK: - G04 取消 / 重试映射

    func testG04_ShouldAbortOnCancelOnlyForOpen() {
        XCTAssertTrue(GroupPlanner.shouldAbortOnCancel(.open))
        XCTAssertFalse(GroupPlanner.shouldAbortOnCancel(.complete),
                       "已 complete 的组不得因普通取消变成 aborted")
        XCTAssertFalse(GroupPlanner.shouldAbortOnCancel(.failed))
        XCTAssertFalse(GroupPlanner.shouldAbortOnCancel(.aborted))
    }

    func testG04_StatusOnRetry() {
        XCTAssertEqual(GroupPlanner.statusOnRetry(of: .open), .aborted)
        XCTAssertEqual(GroupPlanner.statusOnRetry(of: .failed), .aborted)
        XCTAssertNil(GroupPlanner.statusOnRetry(of: .complete), "complete 组重试后状态不变")
        XCTAssertNil(GroupPlanner.statusOnRetry(of: .aborted))
    }

    // MARK: - G05 合法组合矩阵

    func testG05_FiveLegalCombinations() {
        let legal: [(MessageGroupStatus, MessageStatus)] = [
            (.open, .sending),
            (.complete, .sent),
            (.failed, .failed),
            (.aborted, .canceled),
            (.aborted, .failed)
        ]
        for (group, status) in legal {
            XCTAssertTrue(GroupPlanner.isValidCombination(group: group, assistant: status),
                          "\(group) + \(status) 应合法")
        }
    }

    func testG05_SevenIllegalCombinations() {
        let illegal: [(MessageGroupStatus, MessageStatus?)] = [
            (.complete, .canceled),
            (.complete, .failed),
            (.open, .sent),
            (.complete, .sending),
            (.failed, .sending),
            (.aborted, .sending),
            (.aborted, .sent)
        ]
        for (group, status) in illegal {
            XCTAssertFalse(GroupPlanner.isValidCombination(group: group, assistant: status),
                           "\(group) + \(String(describing: status)) 应非法")
        }
        // aborted 组不得没有 assistant 行
        XCTAssertFalse(GroupPlanner.isValidCombination(group: .aborted, assistant: nil))
    }

    func testG05_RecalledIsIndependentOfGroupStatus() {
        for group in MessageGroupStatus.allCases {
            XCTAssertTrue(GroupPlanner.isValidCombination(group: group, assistant: .recalled),
                          "撤回与组状态无关：\(group)")
        }
    }

    // MARK: - G06 纯函数无副作用

    func testG06_PlannerDoesNotMutateInputs() {
        let group = MessageGroup(
            id: "g1",
            conversationID: "c1",
            turnIndex: 3,
            status: .open,
            openedAt: 100,
            userMessageID: "u1"
        )
        let snapshot = group
        _ = GroupPlanner.nextTurnIndex(after: group.turnIndex)
        _ = GroupPlanner.nextSeq(afterMaxExisting: 2)
        _ = GroupPlanner.canTransition(group.status, to: .complete)
        _ = GroupPlanner.isValidCombination(group: group.status, assistant: .sending)
        _ = GroupPlanner.decideGroup(existingOpenGroupID: group.id, isGenerating: true)
        XCTAssertEqual(group, snapshot, "纯函数不得修改传入的组")
    }

    // MARK: - G07 合组判定

    func testG07_DecideGroupAlwaysCreatesNewGroup() {
        XCTAssertEqual(GroupPlanner.decideGroup(existingOpenGroupID: nil, isGenerating: false),
                       .createNew)
        XCTAssertEqual(GroupPlanner.decideGroup(existingOpenGroupID: "g1", isGenerating: false),
                       .createNew)
        XCTAssertEqual(GroupPlanner.decideGroup(existingOpenGroupID: "g1", isGenerating: true),
                       .createNew)
        XCTAssertEqual(GroupPlanner.decideGroup(existingOpenGroupID: "", isGenerating: true),
                       .createNew)
    }
}

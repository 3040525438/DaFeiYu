import XCTest
@testable import DFCore

/// A1 · S 系列：消息状态机（recalled / canceled / failed 分层）
final class MessageStatusCanceledTests: XCTestCase {

    private func assistant(status: MessageStatus, text: String = "半截回答") -> Message {
        Message(
            conversationID: "c1",
            role: .assistant,
            text: text,
            status: status,
            origin: .reply,
            createdAt: 1,
            sentAt: nil
        )
    }

    // MARK: - S01 recalled 与 canceled 互不影响

    func testS01_RecalledAndCanceledAreDistinct() {
        XCTAssertNotEqual(MessageStatus.recalled, MessageStatus.canceled)
        XCTAssertEqual(MessageStatus.recalled.rawValue, "recalled")
        XCTAssertEqual(MessageStatus.canceled.rawValue, "canceled")

        // 撤回态不会被"取消生成"的语义吞并：显式调用才是唯一入口
        let recalled = assistant(status: .recalled)
        XCTAssertEqual(recalled.status, .recalled)
    }

    // MARK: - S02 canceled 字段语义

    func testS02_MarkingCanceledKeepsTextAndSentAt() {
        let sending = Message(
            conversationID: "c1",
            role: .assistant,
            text: "已经生成的部分",
            status: .sending,
            origin: .reply,
            createdAt: 1,
            sentAt: nil
        )
        let canceled = sending.markingCanceled()

        XCTAssertEqual(canceled.status, .canceled)
        XCTAssertEqual(canceled.text, "已经生成的部分", "取消必须保留已生成文本")
        XCTAssertNil(canceled.sentAt, "取消不写 sentAt")
        XCTAssertEqual(sending.status, .sending, "原值不可变")
    }

    // MARK: - S03 可重发性

    func testS03_CanStartSendingOnlyForDraftAndFailed() {
        XCTAssertTrue(assistant(status: .draft).canStartSending)
        XCTAssertTrue(assistant(status: .failed).canStartSending)
        XCTAssertFalse(assistant(status: .canceled).canStartSending, "取消后不直接重发，需重试开新组")
        XCTAssertFalse(assistant(status: .recalled).canStartSending)
        XCTAssertFalse(assistant(status: .sending).canStartSending)
        XCTAssertFalse(assistant(status: .sent).canStartSending)
    }

    // MARK: - S04 组状态与消息状态配对

    func testS04_GroupStatusPairing() {
        XCTAssertTrue(GroupPlanner.isValidCombination(group: .aborted, assistant: .canceled))
        XCTAssertTrue(GroupPlanner.isValidCombination(group: .aborted, assistant: .failed))
        XCTAssertFalse(GroupPlanner.isValidCombination(group: .aborted, assistant: .sent))
        XCTAssertFalse(GroupPlanner.isValidCombination(group: .aborted, assistant: .sending))
        XCTAssertFalse(GroupPlanner.isValidCombination(group: .aborted, assistant: nil))

        XCTAssertTrue(GroupPlanner.isValidCombination(group: .complete, assistant: .sent))
        XCTAssertFalse(GroupPlanner.isValidCombination(group: .complete, assistant: .canceled))
    }

    func testS05_TerminalGroupMustHaveClosedAt() {
        let open = MessageGroup(conversationID: "c1", turnIndex: 1, openedAt: 1)
        XCTAssertFalse(open.isMissingClosedAt)

        var closed = open
        closed.status = .aborted
        XCTAssertTrue(closed.isMissingClosedAt, "终态缺少 closed_at 应被识别为破损")

        closed.closedAt = 2
        XCTAssertFalse(closed.isMissingClosedAt)
    }
}

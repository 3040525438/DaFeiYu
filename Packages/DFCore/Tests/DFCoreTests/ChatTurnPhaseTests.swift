import XCTest
@testable import DFCore

/// D49 / D52：生成状态机与续写 / 隐藏指令的消息判定。
final class ChatTurnPhaseTests: XCTestCase {

    // MARK: - 状态转移

    func testHappyPathTransitions() {
        var phase = ChatTurnPhase.idle
        for next in [ChatTurnPhase.waiting, .thinking, .generating, .paused, .generating, .completed] {
            XCTAssertTrue(phase.canTransition(to: next), "\(phase) → \(next) 应合法")
            phase = next
        }
        XCTAssertTrue(phase.isTerminal)
        XCTAssertTrue(phase.canTransition(to: .idle))
    }

    func testTerminalStatesOnlyGoBackToIdle() {
        for terminal in [ChatTurnPhase.completed, .failed, .stopped] {
            XCTAssertFalse(terminal.canTransition(to: .generating))
            XCTAssertFalse(terminal.canTransition(to: .waiting))
            XCTAssertTrue(terminal.canTransition(to: .idle))
        }
    }

    func testIdleCannotSkipToGenerating() {
        XCTAssertFalse(ChatTurnPhase.idle.canTransition(to: .generating))
        XCTAssertFalse(ChatTurnPhase.waiting.canTransition(to: .generating))
    }

    func testActiveAndTerminalFlags() {
        XCTAssertTrue(ChatTurnPhase.waiting.isActive)
        XCTAssertTrue(ChatTurnPhase.thinking.isActive)
        XCTAssertTrue(ChatTurnPhase.generating.isActive)
        XCTAssertTrue(ChatTurnPhase.paused.isActive)
        XCTAssertFalse(ChatTurnPhase.idle.isActive)
        XCTAssertFalse(ChatTurnPhase.completed.isActive)
        XCTAssertTrue(ChatTurnPhase.completed.isTerminal)
        XCTAssertTrue(ChatTurnPhase.failed.isTerminal)
        XCTAssertTrue(ChatTurnPhase.stopped.isTerminal)
        XCTAssertFalse(ChatTurnPhase.paused.isTerminal, "暂停不是终态")
    }

    func testEveryPhaseHasLabelAndSymbol() {
        for phase in ChatTurnPhase.allCases {
            XCTAssertFalse(phase.label.isEmpty)
            XCTAssertFalse(phase.symbolName.isEmpty)
        }
    }

    // MARK: - 续写 / 隐藏指令

    private func message(
        role: MessageRole,
        origin: MessageOrigin,
        text: String,
        status: MessageStatus = .sent
    ) -> Message {
        Message(
            conversationID: "c1",
            role: role,
            text: text,
            status: status,
            origin: origin
        )
    }

    func testHiddenInstructionOnlyMatchesSystemUserMessage() {
        XCTAssertTrue(
            message(role: .user, origin: .system, text: "续写").isHiddenInstruction
        )
        XCTAssertFalse(
            message(role: .user, origin: .user, text: "你好").isHiddenInstruction,
            "用户真实输入绝不能被隐藏"
        )
        XCTAssertFalse(
            message(role: .assistant, origin: .system, text: "x").isHiddenInstruction
        )
    }

    func testCanContinueWriting() {
        // 正常完成的回复可续写
        XCTAssertTrue(
            message(role: .assistant, origin: .reply, text: "前半段…").canContinueWriting
        )
        // 被取消但保留正文的回复可续写
        XCTAssertTrue(
            message(
                role: .assistant, origin: .reply, text: "前半段…", status: .canceled
            ).canContinueWriting
        )
        // 空正文 / 生成中 / 用户消息 / 已删除 都不可续写
        XCTAssertFalse(
            message(role: .assistant, origin: .reply, text: "   ").canContinueWriting
        )
        XCTAssertFalse(
            message(
                role: .assistant, origin: .reply, text: "x", status: .sending
            ).canContinueWriting
        )
        XCTAssertFalse(
            message(role: .user, origin: .user, text: "你好").canContinueWriting
        )
        var deleted = message(role: .assistant, origin: .reply, text: "x")
        deleted.deletedAt = 1
        XCTAssertFalse(deleted.canContinueWriting)
    }
}

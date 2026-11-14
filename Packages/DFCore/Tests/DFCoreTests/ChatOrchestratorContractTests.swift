import XCTest
@testable import DFCore

/// B1-S1 协议层契约测试（纯类型，不含任何编排实现）。
///
/// 使命：锁定 `OrchestratorEvent` 的形状与 `ChatOrchestrator` 的返回契约，
/// 防止后续实现阶段悄悄改回 `async throws -> Void` 或丢掉 owner 参数。
final class ChatOrchestratorContractTests: XCTestCase {

    // MARK: - S1-01 事件可判等、可跨并发域传递

    func testS1_01_OrchestratorEventIsSendableAndEquatable() {
        func requireSendable<T: Sendable>(_ type: T.Type) {}
        requireSendable(OrchestratorEvent.self)

        let lhs = OrchestratorEvent.turnCompleted(
            groupID: "g1",
            assistantMessageID: "a1",
            citations: ["m1", "m2"]
        )
        let rhs = OrchestratorEvent.turnCompleted(
            groupID: "g1",
            assistantMessageID: "a1",
            citations: ["m1", "m2"]
        )
        XCTAssertEqual(lhs, rhs)

        let differentCitations = OrchestratorEvent.turnCompleted(
            groupID: "g1",
            assistantMessageID: "a1",
            citations: ["m1"]
        )
        XCTAssertNotEqual(lhs, differentCitations)
    }

    // MARK: - S1-02 三种终态互不相等（UI 必须能区分取消与失败）

    func testS1_02_TerminalEventsAreDistinct() {
        let completed = OrchestratorEvent.turnCompleted(
            groupID: "g1", assistantMessageID: "a1", citations: []
        )
        let failed = OrchestratorEvent.turnFailed(
            groupID: "g1", assistantMessageID: "a1", reason: "网络错误"
        )
        let cancelled = OrchestratorEvent.turnCancelled(
            groupID: "g1", assistantMessageID: "a1"
        )

        XCTAssertNotEqual(completed, failed)
        XCTAssertNotEqual(completed, cancelled)
        XCTAssertNotEqual(failed, cancelled)
    }

    // MARK: - S1-03 turnOpened 携带三个真实落库 id

    func testS1_03_TurnOpenedCarriesPersistedIdentifiers() {
        let event = OrchestratorEvent.turnOpened(
            groupID: "group-1",
            userMessageID: "user-1",
            assistantMessageID: "assistant-1"
        )
        guard case let .turnOpened(groupID, userMessageID, assistantMessageID) = event else {
            return XCTFail("事件形状不匹配")
        }
        XCTAssertEqual(groupID, "group-1")
        XCTAssertEqual(userMessageID, "user-1")
        XCTAssertEqual(assistantMessageID, "assistant-1")
    }

    // MARK: - S1-04 协议可被实现，返回事件流且终态后正常结束（不 throw）

    func testS1_04_ProtocolReturnsEventStreamAndFinishesWithoutThrowing() async throws {
        let orchestrator = FakeOrchestrator()
        var received: [OrchestratorEvent] = []

        for try await event in orchestrator.send(text: "你好", conversationID: "c1") {
            received.append(event)
        }

        XCTAssertEqual(received.count, 4)
        if case .turnOpened = received[0] {} else { XCTFail("首事件必须是 turnOpened") }
        if case .assistantDelta = received[1] {} else { XCTFail("第二个事件应是增量文本") }
        if case .assistantReplaced = received[2] {} else { XCTFail("定稿前应有整体替换事件") }
        if case .turnCompleted = received[3] {} else { XCTFail("末事件必须是 turnCompleted") }
    }

    // MARK: - S1-05 取消接口必须携带 owner UUID

    func testS1_05_CancelRequiresOwnerToken() async {
        let owner = UUID()
        let orchestrator = FakeOrchestrator()
        await orchestrator.cancelActiveTurn(owner: owner)

        // 通过 fake 记录证明签名确实要求 owner，且原样传出
        let recorded = orchestrator.lastCancelOwner
        XCTAssertEqual(recorded, owner)
    }
}

// MARK: - 测试替身（仅验证协议形状，不承担任何编排逻辑）

private struct FakeOrchestrator: ChatOrchestrator {
    var observer: ChatLifecycleObserver?

    private let box = OwnerBox()

    var lastCancelOwner: UUID? { box.value }

    func send(text: String, conversationID: String) -> AsyncThrowingStream<OrchestratorEvent, Error> {
        makeStream()
    }

    func retry(messageID: String, conversationID: String) -> AsyncThrowingStream<OrchestratorEvent, Error> {
        makeStream()
    }

    func cancelActiveTurn(owner: UUID) async {
        box.value = owner
    }

    func recoverStaleTurns(conversationID: String) async throws -> RecoveryReport {
        RecoveryReport()
    }

    private func makeStream() -> AsyncThrowingStream<OrchestratorEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(
                .turnOpened(groupID: "g1", userMessageID: "u1", assistantMessageID: "a1")
            )
            continuation.yield(.assistantDelta("你"))
            continuation.yield(.assistantReplaced("你好"))
            continuation.yield(
                .turnCompleted(groupID: "g1", assistantMessageID: "a1", citations: [])
            )
            continuation.finish()
        }
    }
}

/// 用一个引用盒子记录取消入参，避免让 fake 变成可变值类型。
private final class OwnerBox: @unchecked Sendable {
    var value: UUID?
}

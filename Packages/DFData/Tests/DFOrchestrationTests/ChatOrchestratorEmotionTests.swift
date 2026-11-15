import XCTest
import Foundation
import DFCore
@testable import DFData
import DFOrchestration

/// D37：情绪数据源接编排器——当前情绪必须进入 system prompt，缺失时退回静态准则。
final class ChatOrchestratorEmotionTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var groups: GRDBMessageGroupRepository!
    private var turns: GRDBMessageTurnRepository!
    private var messages: GRDBMessageRepository!
    private var references: GRDBMessageReferenceRepository!
    private var units: GRDBContextUnitProvider!
    private var conversationID: String!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrchEmotion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        groups = GRDBMessageGroupRepository(database: database)
        turns = GRDBMessageTurnRepository(database: database)
        messages = GRDBMessageRepository(database: database)
        references = GRDBMessageReferenceRepository(database: database)
        units = GRDBContextUnitProvider(database: database)
        conversationID = try await GRDBConversationRepository(database: database)
            .ensureMainConversation(title: "大肥鱼").id
    }

    override func tearDown() async throws {
        database = nil; groups = nil; turns = nil; messages = nil
        references = nil; units = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    // MARK: - 工具

    private func makeOrchestrator(
        emotion: EmotionState?,
        promptBox: PromptBox
    ) -> ChatOrchestratorImpl {
        let deps = ChatOrchestratorDependencies(
            groups: groups,
            turns: turns,
            messages: messages,
            references: references,
            units: units,
            makeProvider: { StaticProvider() },
            makeRequest: { system, history in
                promptBox.set(system)
                return ChatRequest(model: "fake-model", systemPrompt: system, messages: history)
            },
            currentEmotion: { emotion }
        )
        return ChatOrchestratorImpl(dependencies: deps, pageToken: UUID())
    }

    private func run(
        _ orchestrator: ChatOrchestratorImpl,
        text: String = "今天有点累"
    ) async throws -> [OrchestratorEvent] {
        var events: [OrchestratorEvent] = []
        for try await event in orchestrator.send(text: text, conversationID: conversationID) {
            events.append(event)
        }
        return events
    }

    // MARK: - 用例

    func testEmotionIsInjectedIntoSystemPrompt() async throws {
        let box = PromptBox()
        let orchestrator = makeOrchestrator(
            emotion: EmotionState(kind: .warm, intensity: 0.7, reason: "用户在表达难受或疲惫"),
            promptBox: box
        )
        let events = try await run(orchestrator)

        XCTAssertTrue(events.contains { if case .turnCompleted = $0 { return true }; return false })
        let prompt = try XCTUnwrap(box.value)
        XCTAssertTrue(prompt.contains("当前情绪：温和"))
        XCTAssertTrue(prompt.contains("原因：用户在表达难受或疲惫"))
        XCTAssertTrue(prompt.contains("情绪只影响语气"))
        // 静态准则必须仍在，情绪只是附加片段
        XCTAssertTrue(prompt.contains("【表达方式】"))
    }

    func testNilEmotionKeepsStaticFragmentOnly() async throws {
        let box = PromptBox()
        let orchestrator = makeOrchestrator(emotion: nil, promptBox: box)
        _ = try await run(orchestrator)

        let prompt = try XCTUnwrap(box.value)
        XCTAssertTrue(prompt.contains("【表达方式】"))
        XCTAssertFalse(prompt.contains("当前情绪"))
    }

    func testEmotionWithoutReasonUsesIntensityDescription() async throws {
        let box = PromptBox()
        let orchestrator = makeOrchestrator(
            emotion: EmotionState(kind: .joyful, intensity: 0.7),
            promptBox: box
        )
        _ = try await run(orchestrator)

        let prompt = try XCTUnwrap(box.value)
        XCTAssertTrue(prompt.contains("当前情绪：开心"))
        XCTAssertTrue(prompt.contains("情绪强度 0.70"))
    }
}

// MARK: - 测试替身

/// 记录本轮 system prompt，供断言使用
private final class PromptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ text: String) {
        lock.lock()
        stored = text
        lock.unlock()
    }
}

private struct StaticProvider: ChatModelProvider, @unchecked Sendable {
    var identifier: String { "emotion-static" }
    var capabilities: ModelCapabilities { [.text] }
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text("我在。"))
            continuation.finish()
        }
    }
}

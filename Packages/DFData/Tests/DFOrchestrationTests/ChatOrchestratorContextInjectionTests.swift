import XCTest
import Foundation
import GRDB
import DFCore
@testable import DFData
import DFOrchestration

/// 聊天上下文注入：本地时间（L3）与相关记忆（L4）必须真正进入 system prompt。
/// 模型自身没有系统时钟、也不会自动读取记忆库，缺这两个闭包就会出现
/// "问几点说看不到时间""问过去答不上来"。
final class ChatOrchestratorContextInjectionTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var groups: GRDBMessageGroupRepository!
    private var turns: GRDBMessageTurnRepository!
    private var messages: GRDBMessageRepository!
    private var references: GRDBMessageReferenceRepository!
    private var units: GRDBContextUnitProvider!
    private var conversationID: String!

    /// 跨并发域收集 makeRequest 的入参（测试内串行使用，无并发竞争）
    private final class Captured: @unchecked Sendable {
        var system = ""
        var query = ""
        var limit = 0
    }

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrchInject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        groups = GRDBMessageGroupRepository(database: database)
        turns = GRDBMessageTurnRepository(database: database)
        messages = GRDBMessageRepository(database: database)
        references = GRDBMessageReferenceRepository(database: database)
        units = GRDBContextUnitProvider(database: database)
        let conversation = try await GRDBConversationRepository(database: database)
            .ensureMainConversation(title: "大肥鱼")
        conversationID = conversation.id
    }

    override func tearDown() async throws {
        database = nil
        groups = nil
        turns = nil
        messages = nil
        references = nil
        units = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    func testLocalTimeAndMemoriesAreInjectedIntoSystemPrompt() async throws {
        let captured = Captured()
        let deps = ChatOrchestratorDependencies(
            groups: groups,
            turns: turns,
            messages: messages,
            references: references,
            units: units,
            makeProvider: { ScriptedProvider(deltas: [.text("嗯，记得。")]) },
            makeRequest: { system, history in
                captured.system = system
                return ChatRequest(model: "fake-model", systemPrompt: system, messages: history)
            },
            currentStateText: { "当前时间：2026年11月16日 21:40 星期日（Asia/Shanghai）" },
            retrieveMemories: { query, limit in
                captured.query = query
                captured.limit = limit
                return ["[经历] 2026-10-24 第一次叫她小肥"]
            }
        )
        let orchestrator = ChatOrchestratorImpl(dependencies: deps)
        let text = "现在几点？还记得第一次叫我小肥吗"
        for try await _ in orchestrator.send(text: text, conversationID: conversationID) {}

        XCTAssertTrue(captured.system.contains("【当前状态】"), "缺少 L3 当前状态段落")
        XCTAssertTrue(captured.system.contains("当前时间：2026年11月16日 21:40 星期日"))
        XCTAssertTrue(captured.system.contains("【相关记忆】"), "缺少 L4 相关记忆段落")
        XCTAssertTrue(captured.system.contains("第一次叫她小肥"))
        XCTAssertEqual(captured.query, text, "检索词必须是本轮用户输入")
        XCTAssertEqual(captured.limit, 8)
    }

    func testNilClosuresKeepSystemPromptWithoutInjectedSections() async throws {
        let captured = Captured()
        let deps = ChatOrchestratorDependencies(
            groups: groups,
            turns: turns,
            messages: messages,
            references: references,
            units: units,
            makeProvider: { ScriptedProvider(deltas: [.text("好")]) },
            makeRequest: { system, history in
                captured.system = system
                return ChatRequest(model: "fake-model", systemPrompt: system, messages: history)
            }
        )
        let orchestrator = ChatOrchestratorImpl(dependencies: deps)
        for try await _ in orchestrator.send(text: "你好", conversationID: conversationID) {}

        XCTAssertFalse(captured.system.contains("【相关记忆】"))
        XCTAssertFalse(captured.system.contains("当前时间："))
    }
}

import XCTest
import DFCore
import DFData
@testable import DFOrchestration

/// W8-3：回合结束后的记忆抽取编排（真实 provider 流式输出 → 解析 → 入库）
final class MemoryExtractionCoordinatorTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var service: MemoryProcessingService!
    private var repo: GRDBMemoryRepository!
    private let now: Int64 = 2_000_000

    private let userText = "我最近喜欢上了桂花味的一切，还买了一瓶香水"
    private let assistantText = "桂花确实很温柔。"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFMemoryExtraction-\(UUID().uuidString)", isDirectory: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        service = MemoryProcessingService(database: database, now: { self.now })
        repo = GRDBMemoryRepository(database: database)
    }

    override func tearDownWithError() throws {
        service = nil
        repo = nil
        database = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func completion() -> ChatTurnCompletion {
        ChatTurnCompletion(
            conversationID: "c1",
            userMessageID: "m1",
            assistantMessageID: "m2",
            userText: userText,
            assistantText: assistantText,
            completedAt: now
        )
    }

    private func makeCoordinator(
        provider: StubChatProvider,
        enabled: Bool = true
    ) -> MemoryExtractionCoordinator {
        MemoryExtractionCoordinator(
            processing: service,
            makeRequest: { systemPrompt, userMessage in
                ChatRequest(
                    model: "stub",
                    systemPrompt: systemPrompt,
                    messages: [ChatTurn(role: .user, text: userMessage)],
                    temperature: 0.2,
                    maxTokens: 700
                )
            },
            makeProvider: { provider },
            isEnabled: { enabled }
        )
    }

    func testHandleIngestsParsedCandidates() async throws {
        let json = """
        [{"subject":"user","layer":"semantic","category":"preference","title":"喜欢桂花","content":"用户喜欢桂花味的一切","evidence":"喜欢上了桂花味","importance":0.6,"confidence":0.8}]
        """
        let provider = StubChatProvider(chunks: [json])
        let coordinator = makeCoordinator(provider: provider)

        let handled = await coordinator.handle(completion())
        let report = try XCTUnwrap(handled)
        XCTAssertEqual(report.writtenMemoryIDs.count, 1)

        let id = try XCTUnwrap(report.writtenMemoryIDs.first)
        let loaded = try await repo.memory(id: id)
        let record = try XCTUnwrap(loaded)
        XCTAssertEqual(record.scope, .user)
        XCTAssertEqual(record.content, "用户喜欢桂花味的一切")

        let sources = try await repo.sources(memoryID: id)
        XCTAssertEqual(Set(sources.map(\.sourceID)), ["m1", "m2"])
    }

    func testHandleRoutesHighImportanceToProposal() async throws {
        let json = """
        [{"subject":"user","layer":"semantic","category":"boundary","title":"边界","content":"用户不喜欢被追问行踪","evidence":"还买了一瓶香水","importance":0.9}]
        """
        let coordinator = makeCoordinator(provider: StubChatProvider(chunks: [json]))
        let handled = await coordinator.handle(completion())
        let report = try XCTUnwrap(handled)
        XCTAssertTrue(report.writtenMemoryIDs.isEmpty, "重要/敏感候选不得直接写入")
        XCTAssertEqual(report.proposalIDs.count, 1)
    }

    func testHandleSkipsWhenDisabled() async throws {
        let provider = StubChatProvider(chunks: ["[]"])
        let coordinator = makeCoordinator(provider: provider, enabled: false)
        let report = await coordinator.handle(completion())
        XCTAssertNil(report)
        let calls = await provider.calls
        XCTAssertEqual(calls, 0)
    }

    func testHandleSwallowsProviderFailure() async throws {
        let coordinator = makeCoordinator(provider: StubChatProvider(error: StubError.failed))
        let report = await coordinator.handle(completion())
        XCTAssertNil(report, "模型失败不得影响聊天")
    }

    func testHandleIgnoresUnlocatableEvidence() async throws {
        let json = """
        [{"subject":"user","layer":"semantic","category":"fact","title":"养猫","content":"用户养了两只猫","evidence":"我养了两只猫","importance":0.3}]
        """
        let coordinator = makeCoordinator(provider: StubChatProvider(chunks: [json]))
        let report = await coordinator.handle(completion())
        XCTAssertNil(report)
        let remaining = try await repo.count(scope: nil)
        XCTAssertEqual(remaining, 0)
    }
}

private enum StubError: Error {
    case failed
}

/// 测试替身：按 chunk 顺序吐出文本，并记录调用次数。
private actor StubChatProvider: ChatModelProvider {
    nonisolated let identifier = "stub"
    nonisolated let capabilities: ModelCapabilities = [.text]
    private let chunks: [String]
    private let error: Error?
    private(set) var calls = 0

    init(chunks: [String] = [], error: Error? = nil) {
        self.chunks = chunks
        self.error = error
    }

    nonisolated func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.markCalled()
                if let error {
                    continuation.finish(throwing: error)
                    return
                }
                for chunk in await self.chunksSnapshot() {
                    continuation.yield(.text(chunk))
                }
                continuation.yield(.finished(.stop))
                continuation.finish()
            }
        }
    }

    private func markCalled() {
        calls += 1
    }

    private func chunksSnapshot() -> [String] {
        chunks
    }
}

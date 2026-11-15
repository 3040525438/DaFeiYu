import XCTest
import Foundation
import DFCore
@testable import DFData
import DFOrchestration

/// D10：编排层预算接线。
/// 覆盖：预占 → usage 捕获 → 已确认结算；预算不足时不发模型请求；缺单价记"无法计量"；
/// 请求失败后仍按已产出文本结算，避免漏记成本。
final class ChatOrchestratorBudgetTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var groups: GRDBMessageGroupRepository!
    private var turns: GRDBMessageTurnRepository!
    private var messages: GRDBMessageRepository!
    private var references: GRDBMessageReferenceRepository!
    private var units: GRDBContextUnitProvider!
    private var budget: BudgetService!
    private var conversationID: String!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrchBudget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        groups = GRDBMessageGroupRepository(database: database)
        turns = GRDBMessageTurnRepository(database: database)
        messages = GRDBMessageRepository(database: database)
        references = GRDBMessageReferenceRepository(database: database)
        units = GRDBContextUnitProvider(database: database)
        budget = BudgetService(
            database: database,
            settings: GRDBSettingsRepository(database: database)
        )
        conversationID = try await GRDBConversationRepository(database: database)
            .ensureMainConversation(title: "大肥鱼").id
    }

    override func tearDown() async throws {
        database = nil; groups = nil; turns = nil; messages = nil
        references = nil; units = nil; budget = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    // MARK: - 工具

    private func makeOrchestrator(provider: any ChatModelProvider) -> ChatOrchestratorImpl {
        let budgetService = budget!
        let deps = ChatOrchestratorDependencies(
            groups: groups,
            turns: turns,
            messages: messages,
            references: references,
            units: units,
            makeProvider: { provider },
            makeRequest: { system, history in
                ChatRequest(
                    model: "fake-model",
                    systemPrompt: system,
                    messages: history,
                    maxTokens: 256
                )
            },
            reserveBudget: { request in
                let pricing = try await budgetService.pricing(modelID: request.model)
                let promptTokens = TokenEstimator.estimate(
                    system: request.systemPrompt,
                    turns: request.messages
                )
                let estimate = pricing.map {
                    $0.estimatedCost(
                        promptTokens: promptTokens,
                        maxCompletionTokens: request.maxTokens ?? 256
                    )
                } ?? 0
                return try await budgetService.reserve(
                    scope: .chat,
                    estimatedYuan: estimate,
                    provider: "fake",
                    modelID: request.model
                )
            },
            settleBudget: { reservationID, usage, request, output in
                guard let reservationID else { return }
                let pricing = try? await budgetService.pricing(modelID: request.model)
                try? await budgetService.settle(
                    reservationID: reservationID,
                    usage: usage,
                    pricing: pricing,
                    fallbackPromptTokens: TokenEstimator.estimate(
                        system: request.systemPrompt,
                        turns: request.messages
                    ),
                    fallbackCompletionTokens: TokenEstimator.estimate(output),
                    modelID: request.model
                )
            }
        )
        return ChatOrchestratorImpl(dependencies: deps, pageToken: UUID())
    }

    private func collect(
        _ stream: AsyncThrowingStream<OrchestratorEvent, Error>
    ) async -> (events: [OrchestratorEvent], error: Error?) {
        var events: [OrchestratorEvent] = []
        do {
            for try await event in stream { events.append(event) }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    private func isCompleted(_ event: OrchestratorEvent) -> Bool {
        if case .turnCompleted = event { return true }
        return false
    }

    private func failureReason(_ events: [OrchestratorEvent]) -> String? {
        for event in events {
            if case let .turnFailed(_, _, reason) = event { return reason }
        }
        return nil
    }

    // MARK: - 用例

    func testReserveAndSettleRecordsConfirmedCost() async throws {
        try await budget.savePricing(
            ModelPricing(inputPerThousandYuan: 1, outputPerThousandYuan: 2),
            modelID: "fake-model"
        )
        // 1000 输入 × 1 元/千 + 500 输出 × 2 元/千 = 2 元
        let provider = CountingProvider(deltas: [
            .text("你好"),
            .usage(Usage(promptTokens: 1000, completionTokens: 500)),
            .finished(.stop)
        ])
        let orchestrator = makeOrchestrator(provider: provider)
        let result = await collect(orchestrator.send(text: "在吗", conversationID: conversationID))

        XCTAssertTrue(result.events.contains(where: isCompleted))
        XCTAssertEqual(provider.callCount, 1)

        let records = try await budget.records()
        XCTAssertEqual(records.count, 1, "一次请求只应留下一条成本记录")
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.status, "settled")
        XCTAssertEqual(record.costKind, .confirmed)
        let cost = try XCTUnwrap(record.costYuan)
        XCTAssertEqual(cost, 2.0, accuracy: 0.0001)

        let spend = try await budget.snapshot()
        XCTAssertEqual(spend.confirmedYuan, 2.0, accuracy: 0.0001)
        XCTAssertEqual(spend.unknownCount, 0)
    }

    func testBudgetBlockedPreventsModelCall() async throws {
        try await budget.saveLimits(BudgetLimits(perCallYuan: 0.0001))
        try await budget.savePricing(
            ModelPricing(inputPerThousandYuan: 100, outputPerThousandYuan: 100),
            modelID: "fake-model"
        )
        let provider = CountingProvider(deltas: [
            .text("不该出现"),
            .finished(.stop)
        ])
        let orchestrator = makeOrchestrator(provider: provider)
        let result = await collect(orchestrator.send(text: "在吗", conversationID: conversationID))

        XCTAssertEqual(provider.callCount, 0, "预算不足时不得发起模型请求")
        let reason = try XCTUnwrap(failureReason(result.events))
        XCTAssertTrue(reason.contains("budget_blocked"), "失败原因应可追溯到预算拦截：\(reason)")

        let records = try await budget.records()
        XCTAssertTrue(records.isEmpty, "被拦截的请求不应留下预占记录")
    }

    func testMissingPricingIsRecordedAsUnknownNotEmpty() async throws {
        let provider = CountingProvider(deltas: [
            .text("你好"),
            .usage(Usage(promptTokens: 10, completionTokens: 5)),
            .finished(.stop)
        ])
        let orchestrator = makeOrchestrator(provider: provider)
        _ = await collect(orchestrator.send(text: "在吗", conversationID: conversationID))

        let records = try await budget.records()
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.costKind, .unavailable)
        XCTAssertNil(record.costYuan, "无法计量的费用必须是 NULL，不能记成 0")
        XCTAssertEqual(record.promptTokens, 10, "用量仍应留档")

        let spend = try await budget.snapshot()
        XCTAssertEqual(spend.unknownCount, 1)
        XCTAssertEqual(spend.confirmedYuan, 0, accuracy: 0.0001)
    }

    func testProviderFailureStillSettlesEstimatedCost() async throws {
        try await budget.savePricing(
            ModelPricing(inputPerThousandYuan: 1, outputPerThousandYuan: 2),
            modelID: "fake-model"
        )
        let provider = FailingProvider(text: "部分输出")
        let orchestrator = makeOrchestrator(provider: provider)
        let result = await collect(orchestrator.send(text: "在吗", conversationID: conversationID))

        XCTAssertNotNil(failureReason(result.events))
        let records = try await budget.records()
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.status, "settled", "请求失败也必须结算，避免漏记")
        XCTAssertEqual(record.costKind, .estimated, "没有服务端用量时应标记为估算")
        let cost = try XCTUnwrap(record.costYuan)
        XCTAssertGreaterThan(cost, 0)
    }
}

// MARK: - 测试替身

private final class CountingProvider: ChatModelProvider, @unchecked Sendable {
    var identifier: String { "counting" }
    var capabilities: ModelCapabilities { [.text] }

    private let deltas: [ChatDelta]
    private let lock = NSLock()
    private var count = 0

    init(deltas: [ChatDelta]) {
        self.deltas = deltas
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error> {
        lock.lock()
        count += 1
        lock.unlock()
        let values = deltas
        return AsyncThrowingStream { continuation in
            for delta in values { continuation.yield(delta) }
            continuation.finish()
        }
    }
}

private enum FakeProviderError: Error {
    case boom
}

/// 先产出一段文本再抛错，用于验证"失败也要结算"。
private final class FailingProvider: ChatModelProvider, @unchecked Sendable {
    var identifier: String { "failing" }
    var capabilities: ModelCapabilities { [.text] }

    private let text: String

    init(text: String) {
        self.text = text
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error> {
        let value = text
        return AsyncThrowingStream { continuation in
            continuation.yield(.text(value))
            continuation.finish(throwing: FakeProviderError.boom)
        }
    }
}

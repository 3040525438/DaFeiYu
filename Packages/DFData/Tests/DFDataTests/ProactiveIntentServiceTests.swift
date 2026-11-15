import XCTest
import GRDB
import DFCore
@testable import DFData

/// N-20：意图生成（严格 JSON / 证据逐字）与投递（五重闸门 → 会话 → 主动消息）。
final class ProactiveIntentServiceTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var autonomy: AutonomyService!
    private var proactive: ProactiveMessageService!
    private var service: ProactiveIntentService!

    private let fixedNow: Int64 = 1_700_000_000_000
    private struct ScriptedProvider: ChatModelProvider {
        let identifier = "scripted"
        let capabilities: ModelCapabilities = [.text]
        let response: String

        func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error> {
            let text = response
            return AsyncThrowingStream { continuation in
                continuation.yield(.text(text))
                continuation.yield(.finished(.stop))
                continuation.finish()
            }
        }
    }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFIntent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))

        let fixedClock = AutonomyClock(
            now: { 1_700_000_000_000 },
            minuteOfDay: { _ in 600 },
            dayStart: { _ in 0 }
        )
        autonomy = AutonomyService(database: database, clock: fixedClock)
        proactive = ProactiveMessageService(database: database, now: { 1_700_000_000_000 })
        service = ProactiveIntentService(
            database: database,
            autonomy: autonomy,
            proactive: proactive,
            clock: fixedClock
        )

        try await database.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '大肥鱼', 'main', 1, 1)
            """)
        }
    }

    override func tearDownWithError() throws {
        service = nil
        proactive = nil
        autonomy = nil
        database = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func context() -> ProactiveIntentService.IntentContext {
        ProactiveIntentService.IntentContext(
            conversationID: "c1",
            localTimeText: "2026-11-15 10:00 周六",
            recentTurns: ["用户：今天有点累", "大肥鱼：那早点休息，我在这儿"],
            candidateMemories: ["用户最近在准备考试"],
            feedbackHints: ["用户对 suggestion 表示不感兴趣"]
        )
    }

    private func proposalJSON(
        shouldSend: Bool = true,
        message: String = "刚刚想起你说有点累，记得喝水。",
        evidence: [String] = ["今天有点累"]
    ) -> String {
        let evidenceJSON = evidence.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"should_send": \(shouldSend), "reason": "测试", "evidence": [\(evidenceJSON)], "message": "\(message)"}
        """
    }

    // MARK: - 生成

    func testGeneratePlannedIntent() async throws {
        let proposal = try await service.generate(
            trigger: .message,
            context: context(),
            provider: ScriptedProvider(response: proposalJSON()),
            model: "test-model"
        )
        XCTAssertEqual(proposal.intent.status, .planned)
        XCTAssertEqual(proposal.intent.kind, ProactiveTrigger.message.rawValue)
        XCTAssertEqual(proposal.candidateText, "刚刚想起你说有点累，记得喝水。")
        XCTAssertEqual(proposal.intent.conversationID, "c1")

        let stored = try await service.intent(id: proposal.intent.id)
        XCTAssertEqual(stored?.status, .planned)
        XCTAssertEqual(stored?.evidenceJSON, "[\"今天有点累\"]")
    }

    func testGenerateSkipsWhenModelSaysNo() async throws {
        let proposal = try await service.generate(
            trigger: .message,
            context: context(),
            provider: ScriptedProvider(response: proposalJSON(shouldSend: false, message: "")),
            model: "test-model"
        )
        XCTAssertEqual(proposal.intent.status, .skipped)
        XCTAssertNil(proposal.candidateText)

        let count = try await database.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM proactive_messages") ?? -1
        }
        XCTAssertEqual(count, 0, "不该说的意图不能产生主动消息")
    }

    func testGenerateRejectsInvalidJSON() async throws {
        do {
            _ = try await service.generate(
                trigger: .message,
                context: context(),
                provider: ScriptedProvider(response: "我觉得今天不合适"),
                model: "test-model"
            )
            XCTFail("非 JSON 输出必须被拒绝")
        } catch let error as ProactiveIntentError {
            guard case .invalidOutput = error else {
                return XCTFail("错误类型不符：\(error)")
            }
        }

        let count = try await database.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM conversation_intents") ?? -1
        }
        XCTAssertEqual(count, 0, "解析失败不得写入意图")
    }

    func testGenerateRejectsEmptyContext() async throws {
        let empty = ProactiveIntentService.IntentContext(
            conversationID: "c1",
            localTimeText: "2026-11-15 10:00",
            recentTurns: []
        )
        do {
            _ = try await service.generate(
                trigger: .message,
                context: empty,
                provider: ScriptedProvider(response: proposalJSON()),
                model: "test-model"
            )
            XCTFail("空上下文必须拒绝")
        } catch let error as ProactiveIntentError {
            XCTAssertEqual(error, .emptyContext)
        }
    }

    func testEvidenceMustBeVerbatimFromContext() async throws {
        let raw = proposalJSON(
            evidence: ["今天有点累", "用户小时候养过一只猫"]
        )
        let proposal = try await service.generate(
            trigger: .message,
            context: context(),
            provider: ScriptedProvider(response: raw),
            model: "test-model"
        )
        XCTAssertEqual(proposal.intent.evidenceJSON, "[\"今天有点累\"]", "编造的证据必须被丢弃")
    }

    func testGenerateToleratesCodeFence() async throws {
        let fenced = """
        ```json
        \(proposalJSON())
        ```
        """
        let proposal = try await service.generate(
            trigger: .message,
            context: context(),
            provider: ScriptedProvider(response: fenced),
            model: "test-model"
        )
        XCTAssertEqual(proposal.intent.status, .planned)
    }

    // MARK: - 投递

    func testDispatchDeliversMessageAndProactiveRecord() async throws {
        let proposal = try await service.generate(
            trigger: .message,
            context: context(),
            provider: ScriptedProvider(response: proposalJSON()),
            model: "test-model"
        )
        guard let text = proposal.candidateText else {
            return XCTFail("缺少候选文本")
        }

        let result = try await service.dispatch(intentID: proposal.intent.id, text: text)
        guard case .delivered(let messageID, let proactiveID, let deliveredText, let level) = result else {
            return XCTFail("应放行并投递")
        }
        XCTAssertEqual(deliveredText, text)
        XCTAssertEqual(level, .brief)

        let snapshot = try await database.dbQueue.read { db -> (String, String, String) in
            let message = try Row.fetchOne(
                db,
                sql: "SELECT role, origin, status, sent_at FROM messages WHERE id = ?",
                arguments: [messageID]
            )
            let record = try Row.fetchOne(
                db,
                sql: "SELECT status, sent_at FROM proactive_messages WHERE id = ?",
                arguments: [proactiveID]
            )
            let intent = try Row.fetchOne(
                db,
                sql: "SELECT status FROM conversation_intents WHERE id = ?",
                arguments: [proposal.intent.id]
            )
            XCTAssertEqual(message?["role"], "assistant")
            XCTAssertEqual(message?["origin"], "proactive")
            XCTAssertEqual(message?["status"], "sent")
            XCTAssertNotNil(Int64.fromDatabaseValue(message?["sent_at"] ?? .null))
            XCTAssertEqual(record?["status"], "sent")
            XCTAssertNotNil(Int64.fromDatabaseValue(record?["sent_at"] ?? .null))
            return (message?["origin"] ?? "", record?["status"] ?? "", intent?["status"] ?? "")
        }
        XCTAssertEqual(snapshot.0, "proactive")
        XCTAssertEqual(snapshot.1, "sent")
        XCTAssertEqual(snapshot.2, ProactiveIntentStatus.delivered.rawValue)
    }

    func testDispatchBlockedWhenAutonomyDisabled() async throws {
        var policy = AutonomyPolicy.default
        policy.enabled = false
        try await autonomy.savePolicy(policy)

        let proposal = try await service.generate(
            trigger: .message,
            context: context(),
            provider: ScriptedProvider(response: proposalJSON()),
            model: "test-model"
        )
        guard let text = proposal.candidateText else {
            return XCTFail("缺少候选文本")
        }

        let result = try await service.dispatch(intentID: proposal.intent.id, text: text)
        guard case .blocked(let reason, _) = result else {
            return XCTFail("总开关关闭时必须拦截")
        }
        XCTAssertTrue(reason.contains("总开关"))

        let snapshot = try await database.dbQueue.read { db -> (String, String, Int) in
            let intent = try Row.fetchOne(
                db,
                sql: "SELECT status, suppress_reason FROM conversation_intents WHERE id = ?",
                arguments: [proposal.intent.id]
            )
            let messages = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? -1
            return (intent?["status"] ?? "", intent?["suppress_reason"] ?? "", messages)
        }
        XCTAssertEqual(snapshot.0, ProactiveIntentStatus.suppressed.rawValue)
        XCTAssertTrue(snapshot.1.contains("总开关"))
        XCTAssertEqual(snapshot.2, 0, "被拦截时不得写入会话消息")
    }

    func testDispatchBlockedByDailyLimit() async throws {
        var policy = AutonomyPolicy.default
        policy.dailyLimit = 0
        try await autonomy.savePolicy(policy)

        let proposal = try await service.generate(
            trigger: .message,
            context: context(),
            provider: ScriptedProvider(response: proposalJSON()),
            model: "test-model"
        )
        guard let text = proposal.candidateText else {
            return XCTFail("缺少候选文本")
        }
        let result = try await service.dispatch(intentID: proposal.intent.id, text: text)
        guard case .blocked(let reason, _) = result else {
            return XCTFail("每日上限为 0 时必须拦截")
        }
        XCTAssertTrue(reason.contains("上限"))
    }

    func testDispatchRejectsNonPlannedIntent() async throws {
        let proposal = try await service.generate(
            trigger: .message,
            context: context(),
            provider: ScriptedProvider(response: proposalJSON(shouldSend: false, message: "")),
            model: "test-model"
        )
        do {
            _ = try await service.dispatch(intentID: proposal.intent.id, text: "随便说点什么")
            XCTFail("skipped 意图不可投递")
        } catch let error as ProactiveIntentError {
            guard case .invalidState = error else {
                return XCTFail("错误类型不符：\(error)")
            }
        }
    }

    func testDispatchRejectsEmptyText() async throws {
        let proposal = try await service.generate(
            trigger: .message,
            context: context(),
            provider: ScriptedProvider(response: proposalJSON()),
            model: "test-model"
        )
        do {
            _ = try await service.dispatch(intentID: proposal.intent.id, text: "   ")
            XCTFail("空文本不可投递")
        } catch let error as ProactiveIntentError {
            XCTAssertEqual(error, .emptyMessage)
        }
    }
}

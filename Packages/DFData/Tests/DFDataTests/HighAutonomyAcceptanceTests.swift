import XCTest
import GRDB
import DFCore
@testable import DFData

/// D62：高度自主的端到端验收（服务级）。
///
/// 覆盖授权书要求的可自动验证部分：
/// 主动聊天闭环、用户确认门禁（通知未授权）、免打扰只拦打扰类行为、
/// 主动行为预算、自主创建会话、行为记录可回溯。
///
/// 边界说明：这里串联的是真实 SQLite + 真实服务编排，模型输出由脚本化 Provider 提供；
/// 它验证"决策与落库闭环"，不等于真机 UI 验收，也不能证明 iOS 后台调度一定被系统唤醒。
final class HighAutonomyAcceptanceTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var autonomy: AutonomyService!
    private var proactive: ProactiveMessageService!
    private var intents: ProactiveIntentService!
    private var scheduler: ProactiveScheduler!
    private var messages: GRDBMessageRepository!

    private static let now: Int64 = 1_700_000_000_000
    /// 10:00（在 09:00–21:00 可主动时间窗内）
    private static let minuteOfDay = 10 * 60
    private static let dayStart: Int64 = 1_699_900_000_000

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
            .appendingPathComponent("DFAcceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))

        let clock = AutonomyClock(
            now: { Self.now },
            minuteOfDay: { _ in Self.minuteOfDay },
            dayStart: { _ in Self.dayStart }
        )
        autonomy = AutonomyService(database: database, clock: clock)
        proactive = ProactiveMessageService(database: database, now: { Self.now })
        intents = ProactiveIntentService(
            database: database,
            autonomy: autonomy,
            proactive: proactive,
            clock: clock
        )
        scheduler = ProactiveScheduler(database: database, autonomy: autonomy, clock: clock)
        messages = GRDBMessageRepository(database: database)

        try await database.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '大肥鱼', 'main', 1, 1)
            """)
        }
    }

    override func tearDownWithError() throws {
        messages = nil
        scheduler = nil
        intents = nil
        proactive = nil
        autonomy = nil
        database = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - 夹具

    /// 用户 9 小时前说过话（满足沉默阈值）
    private func seedSilentUser() async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
                VALUES ('u1', 'cu1', 'c1', 'user', 'text', '今天有点累', 'sent', 'user', ?)
                """,
                arguments: [Self.now - 9 * 3_600_000]
            )
        }
    }

    private func context() -> ProactiveIntentService.IntentContext {
        ProactiveIntentService.IntentContext(
            conversationID: "c1",
            localTimeText: "2026-11-15 10:00 周六",
            recentTurns: ["用户：今天有点累", "大肥鱼：那早点休息，我在这儿"],
            candidateMemories: ["用户最近在准备考试"]
        )
    }

    private func yesJSON(message: String = "想起你说有点累，今天好些了吗？") -> String {
        """
        {"should_send": true, "reason": "关心状态", "evidence": ["今天有点累"], "message": "\(message)"}
        """
    }

    private func proactiveMessageCount() throws -> Int {
        try database.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM messages WHERE origin = 'proactive'"
            ) ?? -1
        }
    }

    private func conversationCount(kind: String) throws -> Int {
        try database.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM conversations WHERE kind = ?",
                arguments: [kind]
            ) ?? -1
        }
    }

    // MARK: - 场景 1：主动聊天闭环

    func testProactiveChatEndToEnd() async throws {
        var policy = AutonomyPolicy.default
        policy.allowProactiveMessage = true
        try await autonomy.savePolicy(policy)
        try await seedSilentUser()

        // 1) 调度：久未说话 → 排任务
        let task = try await scheduler.enqueueDueCheckIn()
        let enqueued = try XCTUnwrap(task, "沉默超过 8 小时应排主动检查任务")
        XCTAssertEqual(enqueued.kind, ProactiveTrigger.message.rawValue)

        // 2) 认领并生成意图
        let claimed = try await autonomy.claim(taskID: enqueued.id)
        let proposal = try await intents.generate(
            trigger: .message,
            context: context(),
            provider: ScriptedProvider(response: yesJSON()),
            model: "scripted"
        )
        let text = try XCTUnwrap(proposal.candidateText)

        // 3) 过闸门并投递
        let result = try await intents.dispatch(
            intentID: proposal.intent.id,
            text: text,
            runTrigger: "background"
        )
        guard case .delivered = result else {
            return XCTFail("应投递成功，实际 \(result)")
        }
        try await autonomy.finish(taskID: claimed.id, status: .done)

        // 4) 会话里出现主动消息，主动记录为 sent
        XCTAssertEqual(try proactiveMessageCount(), 1)
        let stored = try await messages.recentMessages(in: "c1", limit: 10)
        XCTAssertTrue(stored.contains { $0.origin == .proactive && $0.text == text })
        let records = try await proactive.list(limit: 10)
        XCTAssertEqual(records.first?.status, .sent)

        // 5) 行为记录可回溯
        let runs = try await autonomy.runs(limit: 20)
        XCTAssertTrue(runs.contains { $0.kind == ProactiveTrigger.message.rawValue && $0.status == .allowed })
    }

    // MARK: - 场景 2：用户确认门禁（通知未授权）

    func testDeliveryBlockedWithoutNotificationAuthorization() async throws {
        var policy = AutonomyPolicy.default
        policy.allowProactiveMessage = true
        policy.notificationLevel = .brief
        try await autonomy.savePolicy(policy)

        let proposal = try await intents.generate(
            trigger: .message,
            context: context(),
            provider: ScriptedProvider(response: yesJSON()),
            model: "scripted"
        )
        let result = try await intents.dispatch(
            intentID: proposal.intent.id,
            text: proposal.candidateText ?? "",
            notificationsAuthorized: false
        )
        guard case .blocked(let reason, _) = result else {
            return XCTFail("未授权通知时应拦截，实际 \(result)")
        }
        XCTAssertTrue(reason.contains("通知授权"))
        XCTAssertEqual(try proactiveMessageCount(), 0, "被拦时不得写入会话")

        let runs = try await autonomy.runs(limit: 20)
        XCTAssertTrue(runs.contains { $0.status == .blocked })
    }

    // MARK: - 场景 3：免打扰只拦打扰类行为

    func testQuietHoursBlockChatButNotMemoryWork() async throws {
        // 23:30 的时钟
        let lateClock = AutonomyClock(
            now: { Self.now },
            minuteOfDay: { _ in 23 * 60 + 30 },
            dayStart: { _ in Self.dayStart }
        )
        let lateAutonomy = AutonomyService(database: database, clock: lateClock)

        let chat = try await lateAutonomy.evaluateSend(trigger: .message)
        XCTAssertFalse(chat.decision.allowed)
        XCTAssertEqual(chat.decision.reason, "当前处于免打扰时段")

        let memory = try await lateAutonomy.evaluateSend(trigger: .memoryConsolidation)
        XCTAssertTrue(memory.decision.allowed, "记忆整理不打扰用户，不受免打扰限制")

        let reflection = try await lateAutonomy.evaluateSend(trigger: .selfReflection)
        XCTAssertTrue(reflection.decision.allowed, "自我反思同样不打扰用户")
    }

    // MARK: - 场景 4：主动行为预算

    func testExhaustedBudgetBlocksProactiveDelivery() async throws {
        var policy = AutonomyPolicy.default
        policy.allowProactiveMessage = true
        policy.dailyBudgetYuan = 0.5
        try await autonomy.savePolicy(policy)

        let proposal = try await intents.generate(
            trigger: .message,
            context: context(),
            provider: ScriptedProvider(response: yesJSON()),
            model: "scripted"
        )
        let result = try await intents.dispatch(
            intentID: proposal.intent.id,
            text: proposal.candidateText ?? "",
            todaySpentYuan: 0.6
        )
        guard case .blocked(let reason, _) = result else {
            return XCTFail("预算耗尽应拦截，实际 \(result)")
        }
        XCTAssertTrue(reason.contains("自主预算"))
        XCTAssertEqual(try proactiveMessageCount(), 0)
    }

    // MARK: - 场景 5：自主创建会话

    func testAutonomousNewConversationEndToEnd() async throws {
        var policy = AutonomyPolicy.default
        policy.allowNewConversation = true
        try await autonomy.savePolicy(policy)
        try await seedSilentUser()

        let task = try await scheduler.enqueueNewConversationIfDue()
        XCTAssertNotNil(task, "开启分项且久未说话时应排新会话评估")
        try await autonomy.claim(taskID: task?.id ?? "")

        let conversationService = ProactiveConversationService(
            database: database,
            conversations: GRDBConversationAdminRepository(database: database),
            autonomy: autonomy,
            clock: AutonomyClock(
                now: { Self.now },
                minuteOfDay: { _ in Self.minuteOfDay },
                dayStart: { _ in Self.dayStart }
            )
        )
        let outcome = try await conversationService.evaluateAndCreate(
            candidate: NewConversationCandidate(
                titleDraft: "备考压力",
                topicAnchor: "用户最近在准备考试",
                dedupeKey: "topic:备考压力"
            )
        )
        guard case .created(let id, let title, _) = outcome else {
            return XCTFail("应新建会话，实际 \(outcome)")
        }
        XCTAssertEqual(title, "备考压力")
        let summary = try await GRDBConversationAdminRepository(database: database).summary(id: id)
        XCTAssertEqual(summary?.kind, ProactiveConversationService.conversationKind)

        // 第二次同主题（不同去重键）：复用已有会话，不再新建
        let again = try await conversationService.evaluateAndCreate(
            candidate: NewConversationCandidate(
                titleDraft: "备考焦虑",
                topicAnchor: nil,
                dedupeKey: "topic:备考焦虑"
            )
        )
        XCTAssertEqual(again.conversationID, id)
        XCTAssertEqual(try conversationCount(kind: ProactiveConversationService.conversationKind), 1)
    }

    // MARK: - 场景 6：行为记录与恢复

    func testBehaviourRecordsCoverAllowedAndBlocked() async throws {
        var policy = AutonomyPolicy.default
        policy.allowProactiveMessage = true
        try await autonomy.savePolicy(policy)

        _ = try await autonomy.evaluateSend(trigger: .message)

        var blockedPolicy = policy
        blockedPolicy.allowProactiveMessage = false
        try await autonomy.savePolicy(blockedPolicy)
        _ = try await autonomy.evaluateSend(trigger: .message)

        let runs = try await autonomy.runs(limit: 20)
        XCTAssertTrue(runs.contains { $0.status == .allowed })
        XCTAssertTrue(runs.contains { $0.status == .blocked })
        XCTAssertTrue(
            runs.filter { $0.status == .blocked }.allSatisfy { !($0.blockReason ?? "").isEmpty },
            "被拦截必须留下原因"
        )
    }
}

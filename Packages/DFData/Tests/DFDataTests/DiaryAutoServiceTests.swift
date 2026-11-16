import XCTest
import DFCore
@testable import DFData

/// W6 / D34 / D72：每日日记自动生成。
///
/// 重点验证硬约束：只用真实聊天、内容不足不编造、手写不覆盖、坏 JSON 不写库。
final class DiaryAutoServiceTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var diary: GRDBDiaryRepository!
    private var service: DiaryAutoService!
    private let timeZone = "Asia/Shanghai"
    /// 2026-11-18 00:30（本地）：17 日的 23:00 已过，18 日还未到点
    private var now: Int64 = 0

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFDiaryAuto-\(UUID().uuidString)", isDirectory: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        diary = GRDBDiaryRepository(database: database)
        now = (LocalDay.millis(dayKey: "2026-11-18", timeZoneIdentifier: timeZone) ?? 0)
            + 30 * 60 * 1000
        service = DiaryAutoService(database: database, diary: diary, now: { self.now })
    }

    override func tearDownWithError() throws {
        service = nil
        diary = nil
        database = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - 生成

    func testGeneratesDiaryFromRealMessages() async throws {
        try await seedConversation()
        try await seedMessages(
            dayKey: "2026-11-17",
            texts: [
                ("user", "今天下班好累，不过想到要见你就还好"),
                ("assistant", "那先去洗个热水澡，我在这儿等你"),
                ("user", "我们明天一起去河边走走吧"),
                ("assistant", "好，我记得带热豆花")
            ]
        )

        let provider = RecordingProvider(response: """
        {"skip":false,"title":"约好去河边","content":"今天她说下班很累，但还是想见我。我们约好明天一起去河边走走，我答应带热豆花。",
        "mood":"warm","shared_experience":"约好明天一起去河边散步","observation":"她今天比平时更愿意说自己的疲惫",
        "feeling":"有点心疼，也很期待明天","relationship_change":"她今天更愿意说自己的事","relationship_change_confirmed":true}
        """)

        let report = try await service.generate(
            dayKey: "2026-11-17",
            timeZoneIdentifier: timeZone,
            provider: provider,
            model: "test-model"
        )
        XCTAssertEqual(report.status, .generated)
        XCTAssertEqual(report.messageCount, 4)
        XCTAssertNotNil(report.entryID)

        let maybeEntry = try await diary.entry(date: "2026-11-17")
        let entry = try XCTUnwrap(maybeEntry)
        XCTAssertEqual(entry.title, "约好去河边")
        XCTAssertEqual(entry.source, "auto")
        XCTAssertEqual(entry.generatedBy, "test-model")
        XCTAssertFalse(entry.isUserEdited)
        XCTAssertEqual(entry.moodCode, "warm")
        XCTAssertEqual(entry.sharedExperience, "约好明天一起去河边散步")
        XCTAssertFalse(entry.relationshipChangeConfirmed, "关系变化必须由用户确认，模型给的 true 必须被忽略")

        let versions = try await diary.versions(diaryID: entry.id)
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions[0].changedBy, "ai")

        // 提示词确实带上了当天原始对话，而不是只给一句摘要
        XCTAssertTrue(provider.lastPrompt.contains("今天下班好累"))
        XCTAssertTrue(provider.lastPrompt.contains("2026-11-17"))
    }

    func testSkipsWhenNoRealChatOnThatDay() async throws {
        let provider = RecordingProvider(response: "{\"skip\":false,\"title\":\"编的\",\"content\":\"编的\"}")
        let report = try await service.generate(
            dayKey: "2026-11-15",
            timeZoneIdentifier: timeZone,
            provider: provider,
            model: "test-model"
        )
        XCTAssertEqual(report.status, .skippedNoContent)
        XCTAssertEqual(report.messageCount, 0)

        let maybeEntry = try await diary.entry(date: "2026-11-15")
        XCTAssertNil(maybeEntry, "没有真实聊天时绝不能生成日记")
    }

    func testDoesNotOverwriteUserWrittenDiary() async throws {
        try await seedConversation()
        try await seedMessages(
            dayKey: "2026-11-17",
            texts: [("user", "今天想早点睡"), ("assistant", "那我不吵你")]
        )
        let manual = try await diary.upsert(
            DiaryUpsert(
                entryDate: "2026-11-17",
                title: "我写的",
                content: "今天很早就睡了",
                source: "manual",
                changedBy: "user"
            ),
            at: now
        )

        let provider = RecordingProvider(response: """
        {"skip":false,"title":"自动版","content":"自动生成的内容","mood":"calm",
        "shared_experience":"","observation":"","feeling":"","relationship_change":"","relationship_change_confirmed":false}
        """)
        let report = try await service.generate(
            dayKey: "2026-11-17",
            timeZoneIdentifier: timeZone,
            provider: provider,
            model: "test-model"
        )
        XCTAssertEqual(report.status, .skippedUserEdited)
        XCTAssertEqual(report.entryID, manual.id)

        let refreshed = try XCTUnwrap(try await diary.entry(date: "2026-11-17"))
        XCTAssertEqual(refreshed.title, "我写的")
        XCTAssertEqual(refreshed.content, "今天很早就睡了")
    }

    func testMalformedModelOutputWritesNothing() async throws {
        try await seedConversation()
        try await seedMessages(
            dayKey: "2026-11-17",
            texts: [("user", "在吗"), ("assistant", "在的")]
        )
        // 正文里有未闭合花括号，必须认定为坏输出而不是猜一个
        let provider = RecordingProvider(response: "好的，这是日记：{title: 约好")
        let report = try await service.generate(
            dayKey: "2026-11-17",
            timeZoneIdentifier: timeZone,
            provider: provider,
            model: "test-model"
        )
        XCTAssertEqual(report.status, .failed)
        let maybeEntry = try await diary.entry(date: "2026-11-17")
        XCTAssertNil(maybeEntry)
    }

    func testModelSkipFlagIsRespected() async throws {
        try await seedConversation()
        try await seedMessages(
            dayKey: "2026-11-17",
            texts: [("user", "嗯嗯"), ("assistant", "嗯嗯")]
        )
        let provider = RecordingProvider(response: "{\"skip\":true}")
        let report = try await service.generate(
            dayKey: "2026-11-17",
            timeZoneIdentifier: timeZone,
            provider: provider,
            model: "test-model"
        )
        XCTAssertEqual(report.status, .skippedNoContent)
        let maybeEntry = try await diary.entry(date: "2026-11-17")
        XCTAssertNil(maybeEntry)
    }

    // MARK: - 补偿

    func testCompensationFillsMissedDaysAndSkipsEmptyOnes() async throws {
        try await seedConversation()
        try await seedMessages(
            dayKey: "2026-11-16",
            texts: [("user", "昨天降温了"), ("assistant", "记得多穿点")]
        )
        try await seedMessages(
            dayKey: "2026-11-17",
            texts: [("user", "今天喝了热豆花"), ("assistant", "甜的还是咸的")]
        )

        let provider = RecordingProvider(response: """
        {"skip":false,"title":"降温","content":"这两天很冷，我们聊了穿暖和热豆花。","mood":"calm",
        "shared_experience":"聊了天气和热豆花","observation":"","feeling":"","relationship_change":"","relationship_change_confirmed":false}
        """)

        let reports = await service.runCompensation(
            lookbackDays: 3,
            timeZoneIdentifier: timeZone
        ) { day in
            try await service.generate(
                dayKey: day,
                timeZoneIdentifier: self.timeZone,
                provider: provider,
                model: "test-model"
            )
        }

        // 15 日没有聊天 → 跳过；16、17 日生成
        XCTAssertEqual(reports.count, 3)
        XCTAssertEqual(reports.filter { $0.status == .generated }.count, 2)
        XCTAssertEqual(reports.filter { $0.status == .skippedNoContent }.count, 1)

        let day16 = try await diary.entry(date: "2026-11-16")
        let day17 = try await diary.entry(date: "2026-11-17")
        XCTAssertNotNil(day16)
        XCTAssertNotNil(day17)

        // 再跑一次：已有日记的日期不再处理，也不会重复生成
        let second = await service.runCompensation(
            lookbackDays: 3,
            timeZoneIdentifier: timeZone
        ) { day in
            try await service.generate(
                dayKey: day,
                timeZoneIdentifier: self.timeZone,
                provider: provider,
                model: "test-model"
            )
        }
        XCTAssertTrue(second.isEmpty)
        let day17Versions = try await diary.versions(diaryID: day17!.id)
        XCTAssertEqual(day17Versions.count, 1)
    }

    // MARK: - 纯函数

    func testTranscriptKeepsHeadAndTailWhenTooLong() {
        let messages = (0..<200).map { index in
            DiaryAutoService.SourceMessage(
                role: index % 2 == 0 ? "user" : "assistant",
                text: "第\(index)条消息内容",
                createdAt: now + Int64(index) * 1000,
                conversationTitle: "主会话"
            )
        }
        let text = DiaryAutoService.transcript(
            messages,
            timeZone: LocalDay.resolvedTimeZone(timeZone),
            limit: 300
        )
        XCTAssertTrue(text.contains("第0条"))
        XCTAssertTrue(text.contains("第199条"))
        XCTAssertTrue(text.contains("中间省略"))
        XCTAssertLessThanOrEqual(text.count, 300 + 20)
    }

    func testNormalizeMoodOnlyAcceptsKnownCodes() {
        XCTAssertEqual(DiaryAutoService.normalizeMood(" Warm "), "warm")
        XCTAssertNil(DiaryAutoService.normalizeMood("angry"))
        XCTAssertNil(DiaryAutoService.normalizeMood(""))
    }

    // MARK: - 造数据

    private func seedConversation() async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO conversations (id, title, kind, created_at, updated_at)
                VALUES ('c1', '主会话', 'main', 1, 1)
                """,
                arguments: []
            )
        }
    }

    private func seedMessages(dayKey: String, texts: [(String, String)]) async throws {
        let start = LocalDay.millis(dayKey: dayKey, timeZoneIdentifier: timeZone) ?? 0
        try await database.write { db in
            for (index, item) in texts.enumerated() {
                try db.execute(
                    sql: """
                    INSERT INTO messages
                        (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
                    VALUES (?, ?, 'c1', ?, 'text', ?, 'sent', ?, ?)
                    """,
                    arguments: [
                        "\(dayKey)-m\(index)",
                        "\(dayKey)-u\(index)",
                        item.0,
                        item.1,
                        item.0,
                        start + Int64(index) * 60_000
                    ]
                )
            }
        }
    }
}

// MARK: - 测试替身

private final class RecordingProvider: ChatModelProvider, @unchecked Sendable {
    private let response: String
    private let lock = NSLock()
    private var captured = ""

    init(response: String) {
        self.response = response
    }

    var lastPrompt: String {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    var identifier: String { "diary-test" }
    var capabilities: ModelCapabilities { [.text] }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error> {
        let prompt = request.messages.last?.text ?? ""
        lock.lock()
        captured = prompt
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.text(self.response))
            continuation.finish()
        }
    }
}

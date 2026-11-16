import XCTest
import GRDB
import DFCore
@testable import DFData

/// 记忆召回兜底：泛问句、跨会话历史、日记、相对时间。
final class RecallContextBuilderTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var memories: GRDBMemoryRepository!
    private var diary: GRDBDiaryRepository!
    private var messages: GRDBMessageRepository!
    private var admin: GRDBConversationAdminRepository!
    private var builder: RecallContextBuilder!

    private let timeZoneIdentifier = "Asia/Shanghai"

    /// 2026-11-17 21:00（上海）
    private var now: Int64 { millis("2026-11-17 21:00:00") }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFRecall-\(UUID().uuidString)", isDirectory: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        memories = GRDBMemoryRepository(database: database)
        diary = GRDBDiaryRepository(database: database)
        messages = GRDBMessageRepository(database: database)
        admin = GRDBConversationAdminRepository(database: database)
        builder = RecallContextBuilder(database: database, memories: memories, diary: diary)
    }

    override func tearDownWithError() throws {
        builder = nil
        admin = nil
        messages = nil
        diary = nil
        memories = nil
        database = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - 夹具

    private func millis(_ text: String) -> Int64 {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return Int64((formatter.date(from: text)!.timeIntervalSince1970 * 1000).rounded())
    }

    private func makeConversation(_ title: String) async throws -> String {
        let summary = try await admin.create(title: title, kind: "chat", at: now)
        return summary.id
    }

    private func insertMessage(
        conversationID: String,
        role: MessageRole,
        text: String,
        at millis: Int64
    ) async throws {
        try await messages.insert(
            Message(
                conversationID: conversationID,
                role: role,
                text: text,
                status: .sent,
                origin: role == .user ? .user : .reply,
                createdAt: millis,
                sentAt: millis
            )
        )
    }

    // MARK: - 测试

    func testGenericRecallQuestionFallsBackToDiaryMemoryAndHistory() async throws {
        // 长期记忆：与问句无字面重合，只能靠显著度兜底
        try await memories.insert(
            MemoryDraft(
                type: "fact",
                title: "小时候的狗",
                content: "用户小时候养过一只叫豆豆的狗。",
                importance: "high",
                confidence: 0.9,
                salience: 0.9
            ),
            at: now
        )
        try await diary.upsert(
            DiaryUpsert(
                entryDate: "2026-11-16",
                title: "河边",
                content: "今天一起去了河边公园。",
                sharedExperience: "一起去河边公园散步，她说风很舒服。",
                observation: "她今天心情比前几天好。",
                feeling: "很放松。",
                source: "auto",
                changedBy: "ai"
            ),
            at: now
        )

        let main = try await makeConversation("主线")
        let old = try await makeConversation("AstrBot 迁移 · QQ")
        try await insertMessage(conversationID: old, role: .user, text: "昨天我们去了河边", at: millis("2026-11-16 20:10:00"))
        try await insertMessage(conversationID: main, role: .user, text: "前天一起看了电影", at: millis("2026-11-15 19:00:00"))

        let lines = await builder.recall(
            query: "你还记得什么",
            currentConversationID: main,
            now: now,
            limit: 12,
            timeZoneIdentifier: timeZoneIdentifier
        )

        XCTAssertTrue(lines.contains { $0.contains("豆豆") }, "应兜底注入高显著度记忆，实际：\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("【日记·2026-11-16】") }, "应注入最近日记，实际：\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("河边") }, "应注入跨会话历史，实际：\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("电影") }, "应注入本会话更早的消息，实际：\(lines)")
        XCTAssertLessThanOrEqual(lines.count, 12)
    }

    func testOrdinaryQuestionWithoutHitsDoesNotPollutePrompt() async throws {
        try await diary.upsert(
            DiaryUpsert(entryDate: "2026-11-16", content: "普通的一天", changedBy: "user"),
            at: now
        )
        let main = try await makeConversation("主线")
        try await insertMessage(conversationID: main, role: .user, text: "今天好热", at: millis("2026-11-17 12:00:00"))

        let lines = await builder.recall(
            query: "今天好热",
            currentConversationID: main,
            now: now,
            limit: 12,
            timeZoneIdentifier: timeZoneIdentifier
        )
        XCTAssertTrue(lines.isEmpty, "日常闲聊不应被历史记忆污染，实际：\(lines)")
    }

    func testYesterdayPhraseLimitsDiaryRange() async throws {
        try await diary.upsert(
            DiaryUpsert(entryDate: "2026-11-16", content: "昨天在河边", changedBy: "user"),
            at: now
        )
        try await diary.upsert(
            DiaryUpsert(entryDate: "2026-11-17", content: "今天在图书馆", changedBy: "user"),
            at: now
        )

        let lines = await builder.recall(
            query: "你还记得昨天吗",
            currentConversationID: nil,
            now: now,
            limit: 12,
            timeZoneIdentifier: timeZoneIdentifier
        )
        XCTAssertTrue(lines.contains { $0.contains("【日记·2026-11-16】") && $0.contains("河边") }, "实际：\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("【日记·2026-11-17】") }, "昨天应排除今天，实际：\(lines)")
    }

    func testKeywordHitIsPreferredAndDoesNotForceFallback() async throws {
        try await memories.insert(
            MemoryDraft(type: "fact", title: "怕打雷", content: "用户很怕打雷。", confidence: 0.7),
            at: now
        )
        let lines = await builder.recall(
            query: "我打雷的时候会怕",
            currentConversationID: nil,
            now: now,
            limit: 12,
            timeZoneIdentifier: timeZoneIdentifier
        )
        XCTAssertTrue(lines.contains { $0.contains("怕打雷") }, "关键词命中应进提示词，实际：\(lines)")
    }

    func testRecallCueDetection() {
        XCTAssertTrue(RecallContextBuilder.hasRecallCue("你还记得吗"))
        XCTAssertTrue(RecallContextBuilder.hasRecallCue("我们上周聊了什么"))
        XCTAssertTrue(RecallContextBuilder.hasRecallCue("看看以前的日记"))
        XCTAssertFalse(RecallContextBuilder.hasRecallCue("今天吃什么"))
        XCTAssertFalse(RecallContextBuilder.hasRecallCue(""))
    }
}

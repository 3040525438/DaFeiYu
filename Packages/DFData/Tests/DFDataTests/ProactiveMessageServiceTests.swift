import XCTest
import GRDB
import DFCore
@testable import DFData

/// 主动消息治理：发送留痕 / 收藏 / 不感兴趣 / 软删除 / 触发原因（W7-6 / D50）
final class ProactiveMessageServiceTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var service: ProactiveMessageService!
    private let now: Int64 = 500_000

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFProactive-\(UUID().uuidString)", isDirectory: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        service = ProactiveMessageService(database: database, now: { self.now })
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testRecordDefaults() async throws {
        let message = try await service.record(
            text: "今天想起你说过喜欢下雨天",
            triggerKind: "message",
            plannedAt: now - 1_000,
            triggerRef: ProactiveTriggerRef.memory("m-1")
        )
        XCTAssertEqual(message.status, .planned)
        XCTAssertEqual(message.feedback, .none)
        XCTAssertFalse(message.isFavorite)
        XCTAssertEqual(message.notifyLevel, .brief)
        XCTAssertEqual(message.triggerRef, "memory:m-1")

        do {
            _ = try await service.record(text: "  ", triggerKind: "message", plannedAt: now)
            XCTFail("内容为空应失败")
        } catch let error as ProactiveMessageError {
            XCTAssertEqual(error, .emptyText)
        }
    }

    func testMarkSentOnlyOnce() async throws {
        let message = try await service.record(text: "在忙吗", triggerKind: "message", plannedAt: now)
        let sent = try await service.markSent(id: message.id, messageID: "msg-1")
        XCTAssertEqual(sent.status, .sent)
        XCTAssertEqual(sent.sentAt, now)
        XCTAssertEqual(sent.messageID, "msg-1")

        do {
            _ = try await service.markSent(id: message.id, messageID: "msg-2")
            XCTFail("已发送的消息不能重复发送")
        } catch let error as ProactiveMessageError {
            XCTAssertEqual(error, .invalidState("当前为 sent，只有 planned 可发送"))
        }
    }

    func testMarkSuppressed() async throws {
        let message = try await service.record(text: "随手一说", triggerKind: "suggestion", plannedAt: now)
        try await service.markSuppressed(id: message.id, reason: "当前处于免打扰时段")

        let stored = try await service.list()
        XCTAssertEqual(stored.first?.status, .suppressed)
        XCTAssertEqual(stored.first?.suppressReason, "当前处于免打扰时段")
    }

    func testFavoriteAndFeedback() async throws {
        let message = try await service.record(text: "晚安", triggerKind: "message", plannedAt: now)
        let favorite = try await service.setFavorite(id: message.id, favorite: true)
        XCTAssertTrue(favorite.isFavorite)
        let favorites = try await service.favorites()
        XCTAssertEqual(favorites.map(\.id), [message.id])

        let feedback = try await service.setFeedback(id: message.id, feedback: .notInterested)
        XCTAssertEqual(feedback.feedback, .notInterested)
        XCTAssertEqual(feedback.feedbackAt, now)

        let suppressed = try await service.suppressedTriggerKinds()
        XCTAssertTrue(suppressed.contains("message"))
        XCTAssertFalse(suppressed.contains("memory_consolidation"))
    }

    func testSuppressionWindowExpires() async throws {
        let message = try await service.record(text: "旧消息", triggerKind: "message", plannedAt: now)
        _ = try await service.setFeedback(id: message.id, feedback: .notInterested)
        try await database.write { db in
            try db.execute(
                sql: "UPDATE proactive_messages SET feedback_at = ? WHERE id = ?",
                arguments: [self.now - ProactiveMessageService.suppressionWindowMillis - 1, message.id]
            )
        }
        let suppressed = try await service.suppressedTriggerKinds()
        XCTAssertTrue(suppressed.isEmpty, "超过窗口后不再抑制同类")
    }

    func testSoftDeleteKeepsRecord() async throws {
        let message = try await service.record(text: "就不发了", triggerKind: "message", plannedAt: now)
        try await service.delete(id: message.id)
        try await service.delete(id: message.id)

        let visible = try await service.list()
        XCTAssertTrue(visible.isEmpty)
        let all = try await service.list(includeDeleted: true)
        XCTAssertEqual(all.first?.status, .deleted)

        let rows = try await int("SELECT count(*) FROM proactive_messages")
        XCTAssertEqual(rows, 1, "删除必须是软删除，保留触发原因")
    }

    func testExplainIncludesIntentAndMemoryRef() async throws {
        try await database.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c-1', '主会话', 'main', 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO conversation_intents
                (id, conversation_id, kind, status, trigger, reason, evidence_json,
                 confidence, priority, planned_at, created_at)
            VALUES ('i-1', 'c-1', 'followup', 'planned', 'autonomy', '上次聊到一半',
                    '[\"m-1\"]', 0.8, 2, ?, ?)
            """, arguments: [self.now, self.now])
        }
        let message = try await service.record(
            text: "接着聊",
            triggerKind: "message",
            plannedAt: now,
            triggerRef: ProactiveTriggerRef.memory("m-1"),
            intentID: "i-1"
        )
        let explanation = try await service.explain(id: message.id)
        XCTAssertEqual(explanation.triggerKind, "message")
        XCTAssertEqual(explanation.intentReason, "上次聊到一半")
        XCTAssertEqual(explanation.relatedMemoryID, "m-1")
        XCTAssertEqual(explanation.evidenceJSON, "[\"m-1\"]")

        do {
            _ = try await service.explain(id: "missing")
            XCTFail("不存在的消息应报错")
        } catch let error as ProactiveMessageError {
            XCTAssertEqual(error, .notFound("missing"))
        }
    }

    private func int(_ sql: String) async throws -> Int? {
        try await database.dbQueue.read { db in try Int.fetchOne(db, sql: sql) }
    }
}

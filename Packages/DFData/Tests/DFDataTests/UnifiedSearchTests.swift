import XCTest
import GRDB
import DFCore
@testable import DFData

/// D25 跨域统一检索 + D51 归档可检索。
final class UnifiedSearchTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var search: GRDBUnifiedSearchRepository!
    private var conversations: GRDBConversationAdminRepository!
    private var deletion: GRDBMessageDeletionRepository!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFUnifiedSearch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        search = GRDBUnifiedSearchRepository(database: database)
        conversations = GRDBConversationAdminRepository(database: database)
        deletion = GRDBMessageDeletionRepository(database: database)
        try await seed()
    }

    override func tearDownWithError() throws {
        search = nil
        conversations = nil
        deletion = nil
        database = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func seed() async throws {
        try await database.write { db in
            for (id, title, kind, millis) in [
                ("c1", "主会话", "main", 1000),
                ("c2", "摄影旧会话", "chat", 2000)
            ] {
                try db.execute(
                    sql: """
                    INSERT INTO conversations (id, title, kind, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [id, title, kind, millis, millis]
                )
            }
            for (id, conversation, text, millis) in [
                ("m1", "c1", "今天去看了摄影展", 1000),
                ("m2", "c2", "摄影笔记第二篇", 2000)
            ] {
                try db.execute(
                    sql: """
                    INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
                    VALUES (?, ?, ?, 'user', 'text', ?, 'sent', 'user', ?)
                    """,
                    arguments: [id, "uuid-\(id)", conversation, text, millis]
                )
            }
        }

        // 消息索引
        _ = try await GRDBChatSearchRepository(database: database).rebuildIndex(conversationID: nil)

        // 记忆（写入时同步 memory_fts）
        _ = try await GRDBMemoryRepository(database: database).insert(
            MemoryDraft(
                title: "摄影爱好",
                content: "用户喜欢拍海边照片，也常聊摄影器材",
                scope: .user,
                dedupeKey: "hobby:photography",
                sources: [MemorySourceRef(sourceType: "message", sourceID: "m1", excerpt: "今天去看了摄影展")]
            ),
            at: 1500
        )

        // 日记（写入时同步 diary_fts）
        _ = try await GRDBDiaryRepository(database: database).upsert(
            DiaryUpsert(
                entryDate: "2026-11-14",
                title: "海边散步",
                content: "今天和用户去了海边，聊了很多摄影的事"
            ),
            at: 1600
        )

        // 附件 OCR 文本（写入时同步 attachment_text_fts）
        let attachment = try await GRDBAttachmentRepository(database: database).ensure(
            NewAttachment(
                sha256: "sha-cat",
                kind: "image",
                relPath: "ab/cd/cat.png",
                byteSize: 2048,
                mime: "image/png",
                createdAt: 2100
            )
        )
        try await GRDBAttachmentRepository(database: database).link(
            messageID: "m2",
            attachmentID: attachment.id,
            sort: 0
        )
        _ = try await GRDBAttachmentTextRepository(database: database).upsert(
            attachmentID: attachment.id,
            kind: .ocr,
            text: "照片里是一只橘猫",
            language: "zh",
            engine: "vision",
            confidence: 0.9,
            at: 2200
        )
    }

    // MARK: - 跨域命中

    func testSearchesAcrossAllDomains() async throws {
        let hits = try await search.search(query: "摄影")
        XCTAssertTrue(hits.contains { $0.domain == .message })
        XCTAssertTrue(hits.contains { $0.domain == .memory })
        XCTAssertTrue(hits.contains { $0.domain == .diary })
        XCTAssertFalse(hits.contains { $0.domain == .attachment }, "附件文本没有摄影二字")

        // 域顺序固定，便于 UI 分组
        let domains = hits.map(\.domain)
        XCTAssertEqual(domains, domains.sorted { lhs, rhs in
            (SearchDomain.allCases.firstIndex(of: lhs) ?? 0) < (SearchDomain.allCases.firstIndex(of: rhs) ?? 0)
        })
    }

    func testDomainFilterReturnsOnlyRequestedDomain() async throws {
        let hits = try await search.search(query: "摄影", domains: [.diary], limitPerDomain: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.domain, .diary)
        XCTAssertEqual(hits.first?.diaryDate, "2026-11-14")
    }

    func testAttachmentHitCarriesMessageAndConversationLocator() async throws {
        let hits = try await search.search(query: "橘猫", domains: [.attachment], limitPerDomain: 10)
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.domain, .attachment)
        XCTAssertEqual(hit.messageID, "m2")
        XCTAssertEqual(hit.conversationID, "c2")
        XCTAssertTrue(hit.snippet.contains("橘猫"))
    }

    func testSnippetUsesOriginalTextNotBigramFragments() async throws {
        let hits = try await search.search(query: "摄影", domains: [.message], limitPerDomain: 10)
        XCTAssertFalse(hits.isEmpty)
        for hit in hits {
            XCTAssertTrue(hit.snippet.contains("摄影"), "摘要必须来自原文，不能是 bigram 碎片")
            XCTAssertFalse(hit.snippet.contains("影摄"))
        }
    }

    // MARK: - 排除与归档

    func testDeletedAndRevokedMessagesExcluded() async throws {
        _ = try await deletion.softDelete(.ids(["m1"]), in: nil, at: 5000)
        try await GRDBMessageEditingRepository(database: database).revokeMessage(id: "m2", reason: nil, revokedAt: 5000)

        let hits = try await search.search(query: "摄影", domains: [.message], limitPerDomain: 10)
        XCTAssertTrue(hits.isEmpty, "软删与撤回的消息不得出现在检索结果里")
    }

    func testArchivedConversationMessagesRemainSearchable() async throws {
        // D51：归档只影响列表分组，不影响检索
        try await conversations.setArchived(id: "c2", archived: true, at: 6000)

        let hits = try await search.search(query: "摄影笔记", domains: [.message], limitPerDomain: 10)
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.conversationID, "c2")
        XCTAssertEqual(hit.messageID, "m2")
    }

    func testArchivedConversationHiddenFromActiveListButKeptInArchivedList() async throws {
        try await conversations.setArchived(id: "c2", archived: true, at: 6000)
        let active = try await conversations.list(.active).map(\.id)
        let archived = try await conversations.list(.archived).map(\.id)
        XCTAssertFalse(active.contains("c2"))
        XCTAssertTrue(archived.contains("c2"))
    }

    // MARK: - 边界

    func testEmptyQueryReturnsNoHits() async throws {
        let hits = try await search.search(query: "   \n ")
        XCTAssertTrue(hits.isEmpty)
    }

    func testEmptyDomainSetReturnsNoHits() async throws {
        let hits = try await search.search(query: "摄影", domains: [], limitPerDomain: 10)
        XCTAssertTrue(hits.isEmpty)
    }

    func testLimitPerDomainIsAppliedPerDomain() async throws {
        let hits = try await search.search(query: "摄影", domains: [.message], limitPerDomain: 1)
        XCTAssertEqual(hits.count, 1)
    }
}

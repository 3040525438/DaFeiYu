import XCTest
import GRDB
import DFCore
@testable import DFData

/// W4-1 ~ W4-6 数据层：附件、OCR/转写文本、多图分析。
final class MultimodalTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var attachments: GRDBAttachmentRepository!
    private var texts: GRDBAttachmentTextRepository!
    private var analyses: GRDBImageAnalysisRepository!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFMulti-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        attachments = GRDBAttachmentRepository(database: database)
        texts = GRDBAttachmentTextRepository(database: database)
        analyses = GRDBImageAnalysisRepository(database: database)
        try await seed()
    }

    override func tearDownWithError() throws {
        attachments = nil
        texts = nil
        analyses = nil
        database = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func seed() async throws {
        try await database.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '主会话', 'main', 1, 1)
            """)
            for (id, text) in [("m1", "看这张图"), ("m2", "还有这张")] {
                try db.execute(
                    sql: """
                    INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
                    VALUES (?, ?, 'c1', 'user', 'text', ?, 'sent', 'user', 2)
                    """,
                    arguments: [id, "uuid-\(id)", text]
                )
            }
        }
    }

    private func newAttachment(_ sha: String, kind: String = "image", at millis: Int64 = 100) -> NewAttachment {
        NewAttachment(
            sha256: sha,
            kind: kind,
            relPath: "ab/cd/\(sha).png",
            byteSize: 2048,
            mime: kind == "audio" ? "audio/m4a" : "image/png",
            createdAt: millis
        )
    }

    // MARK: - 附件

    func testEnsureDeduplicatesBySHA() async throws {
        let first = try await attachments.ensure(newAttachment("sha-1"))
        let second = try await attachments.ensure(newAttachment("sha-1"))
        XCTAssertEqual(first.id, second.id, "相同内容只保留一行")

        let count = try await database.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM attachments") ?? -1
        }
        XCTAssertEqual(count, 1)
    }

    func testAttachmentsInMessageFollowSortOrder() async throws {
        let a = try await attachments.ensure(newAttachment("sha-a"))
        let b = try await attachments.ensure(newAttachment("sha-b"))
        try await attachments.link(messageID: "m1", attachmentID: a.id, sort: 2)
        try await attachments.link(messageID: "m1", attachmentID: b.id, sort: 1)

        let list = try await attachments.attachments(inMessage: "m1", includeDeleted: false)
        XCTAssertEqual(list.map(\.id), [b.id, a.id], "按 sort 升序")
    }

    func testSoftDeletedAttachmentStillVisibleWhenRequested() async throws {
        let a = try await attachments.ensure(newAttachment("sha-a"))
        try await attachments.link(messageID: "m1", attachmentID: a.id, sort: 0)
        try await attachments.softDelete(id: a.id, reason: "用户删除", at: 500)

        let visible = try await attachments.attachments(inMessage: "m1", includeDeleted: false)
        XCTAssertTrue(visible.isEmpty)
        let all = try await attachments.attachments(inMessage: "m1", includeDeleted: true)
        XCTAssertEqual(all.count, 1)
        XCTAssertTrue(all[0].isDeleted)

        try await attachments.restore(id: a.id)
        let restored = try await attachments.attachment(id: a.id)
        XCTAssertFalse(restored?.isDeleted ?? true)
    }

    func testMessageIDsUsingAttachmentListsReferences() async throws {
        let a = try await attachments.ensure(newAttachment("sha-a"))
        try await attachments.link(messageID: "m1", attachmentID: a.id, sort: 0)
        try await attachments.link(messageID: "m2", attachmentID: a.id, sort: 0)

        let ids = try await attachments.messageIDs(usingAttachment: a.id)
        XCTAssertEqual(ids, ["m1", "m2"])

        try await attachments.unlink(messageID: "m1", attachmentID: a.id)
        let remaining = try await attachments.messageIDs(usingAttachment: a.id)
        XCTAssertEqual(remaining, ["m2"])
    }

    func testUnreferencedReportsOnlyUnlinkedOldAttachments() async throws {
        let linked = try await attachments.ensure(newAttachment("sha-linked", at: 100))
        let orphan = try await attachments.ensure(newAttachment("sha-orphan", at: 100))
        let fresh = try await attachments.ensure(newAttachment("sha-fresh", at: 9000))
        try await attachments.link(messageID: "m1", attachmentID: linked.id, sort: 0)

        let result = try await attachments.unreferenced(before: 5000, limit: 10)
        XCTAssertEqual(result.map(\.id), [orphan.id])
        XCTAssertFalse(result.contains { $0.id == fresh.id }, "晚于截止时间的附件不算候选")
    }

    func testSetMetricsDoesNotEraseExistingValues() async throws {
        let a = try await attachments.ensure(newAttachment("sha-a"))
        try await attachments.setMetrics(id: a.id, width: 800, height: 600, durationMs: nil, thumbnailRelPath: "t.png")

        var current = try await attachments.attachment(id: a.id)
        XCTAssertEqual(current?.width, 800)
        XCTAssertEqual(current?.height, 600)
        XCTAssertEqual(current?.thumbnailRelPath, "t.png")

        // 只补时长，不应把宽高清空
        try await attachments.setMetrics(id: a.id, width: nil, height: nil, durationMs: 3000, thumbnailRelPath: nil)
        current = try await attachments.attachment(id: a.id)
        XCTAssertEqual(current?.width, 800)
        XCTAssertEqual(current?.height, 600)
        XCTAssertEqual(current?.durationMs, 3000)
        XCTAssertEqual(current?.thumbnailRelPath, "t.png")
    }

    // MARK: - OCR / 转写

    func testOCRUpsertIsSearchableAndOverwrites() async throws {
        let a = try await attachments.ensure(newAttachment("sha-a"))
        try await texts.upsert(
            attachmentID: a.id, kind: .ocr, text: "海报上写着摄影展",
            language: "zh", engine: "vision", confidence: 0.92, at: 1000
        )

        let hits = try await texts.search(query: "摄影展", limit: 10)
        XCTAssertEqual(hits, [a.id])

        try await texts.upsert(
            attachmentID: a.id, kind: .ocr, text: "海报改成了签售会",
            language: "zh", engine: "vision", confidence: 0.9, at: 2000
        )
        let oldHits = try await texts.search(query: "摄影展", limit: 10)
        XCTAssertTrue(oldHits.isEmpty, "覆盖后不得保留旧索引")
        let newHits = try await texts.search(query: "签售会", limit: 10)
        XCTAssertEqual(newHits, [a.id])

        let record = try await texts.text(attachmentID: a.id, kind: .ocr)
        XCTAssertEqual(record?.updatedAt, 2000)
        XCTAssertEqual(record?.engine, "vision")
    }

    func testOCROfMissingAttachmentIsRejected() async throws {
        do {
            try await texts.upsert(
                attachmentID: "missing", kind: .ocr, text: "文字",
                language: nil, engine: "vision", confidence: nil, at: 1000
            )
            XCTFail("附件不存在必须报错")
        } catch let error as MultimodalError {
            XCTAssertEqual(error, .notFound)
        }
    }

    func testOCROfDeletedAttachmentIsHiddenFromSearch() async throws {
        let a = try await attachments.ensure(newAttachment("sha-a"))
        try await texts.upsert(
            attachmentID: a.id, kind: .ocr, text: "海边落日",
            language: "zh", engine: "vision", confidence: nil, at: 1000
        )
        try await attachments.softDelete(id: a.id, reason: nil, at: 2000)

        let hits = try await texts.search(query: "落日", limit: 10)
        XCTAssertTrue(hits.isEmpty, "已删附件不应出现在检索结果里")
    }

    func testOCROfAndTranscriptShareOneIndexEntry() async throws {
        let a = try await attachments.ensure(newAttachment("sha-a", kind: "audio"))
        try await texts.upsert(
            attachmentID: a.id, kind: .ocr, text: "画面里有海浪",
            language: nil, engine: "vision", confidence: nil, at: 1000
        )
        try await texts.upsert(
            attachmentID: a.id, kind: .transcript, text: "他说想去海边",
            language: "zh", engine: "asr", confidence: 0.8, at: 1100
        )

        let indexCount = try await database.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM attachment_text_fts WHERE attachment_id = ?",
                arguments: [a.id]
            ) ?? -1
        }
        XCTAssertEqual(indexCount, 1, "同一附件只保留一行合并索引")

        let waveHits = try await texts.search(query: "海浪", limit: 10)
        XCTAssertEqual(waveHits, [a.id])
        let seaHits = try await texts.search(query: "海边", limit: 10)
        XCTAssertEqual(seaHits, [a.id])
    }

    func testEmptyTextRemovesKind() async throws {
        let a = try await attachments.ensure(newAttachment("sha-a"))
        try await texts.upsert(
            attachmentID: a.id, kind: .ocr, text: "临时文字",
            language: nil, engine: "vision", confidence: nil, at: 1000
        )
        try await texts.upsert(
            attachmentID: a.id, kind: .ocr, text: "   ",
            language: nil, engine: "vision", confidence: nil, at: 2000
        )
        let record = try await texts.text(attachmentID: a.id, kind: .ocr)
        XCTAssertNil(record)
        let hits = try await texts.search(query: "临时文字", limit: 10)
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: - 多图分析

    func testImageAnalysisLifecycle() async throws {
        let a = try await attachments.ensure(newAttachment("sha-a"))
        let b = try await attachments.ensure(newAttachment("sha-b"))

        let created = try await analyses.create(
            conversationID: "c1", messageID: "m1",
            attachmentIDs: [a.id, b.id], prompt: "比较这两张图",
            modelConfigID: "cfg-1", at: 1000
        )
        XCTAssertEqual(created.status, "pending")
        XCTAssertEqual(created.attachmentIDs, [a.id, b.id])
        XCTAssertEqual(created.prompt, "比较这两张图")

        try await analyses.finish(id: created.id, result: "两张都是海边", status: "done", at: 2000)
        let finished = try await analyses.analysis(id: created.id)
        XCTAssertEqual(finished?.status, "done")
        XCTAssertEqual(finished?.result, "两张都是海边")
        XCTAssertEqual(finished?.finishedAt, 2000)

        let byMessage = try await analyses.analyses(messageID: "m1")
        XCTAssertEqual(byMessage.map(\.id), [created.id])
        let byConversation = try await analyses.analyses(conversationID: "c1", limit: 10)
        XCTAssertEqual(byConversation.map(\.id), [created.id])
    }

    func testImageAnalysisRejectsEmptyInputsAndBadStatus() async throws {
        let a = try await attachments.ensure(newAttachment("sha-a"))

        do {
            _ = try await analyses.create(
                conversationID: nil, messageID: nil, attachmentIDs: [],
                prompt: "x", modelConfigID: nil, at: 1
            )
            XCTFail("空图片列表必须拒绝")
        } catch let error as MultimodalError {
            XCTAssertEqual(error, .emptyAttachments)
        }

        do {
            _ = try await analyses.create(
                conversationID: nil, messageID: nil, attachmentIDs: [a.id],
                prompt: "  ", modelConfigID: nil, at: 1
            )
            XCTFail("空指令必须拒绝")
        } catch let error as MultimodalError {
            XCTAssertEqual(error, .emptyPrompt)
        }

        let created = try await analyses.create(
            conversationID: nil, messageID: nil, attachmentIDs: [a.id],
            prompt: "看看", modelConfigID: nil, at: 1
        )
        do {
            try await analyses.finish(id: created.id, result: "x", status: "unknown", at: 2)
            XCTFail("非法状态必须拒绝")
        } catch let error as MultimodalError {
            XCTAssertEqual(error, .invalidStatus("unknown"))
        }
    }
}

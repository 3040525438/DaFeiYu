import XCTest
import GRDB
import DFCore
@testable import DFData

/// D57：附件删除前引用检查、解除引用与批量清理。
final class AttachmentReferenceServiceTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var service: GRDBAttachmentReferenceService!
    private var attachments: GRDBAttachmentRepository!

    private var inUseID = ""
    private var staleID = ""
    private var orphanID = ""

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFAttachRef-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        service = GRDBAttachmentReferenceService(database: database)
        attachments = GRDBAttachmentRepository(database: database)
        try await seed()
    }

    override func tearDownWithError() throws {
        service = nil
        attachments = nil
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
            try db.execute(sql: """
            INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
            VALUES ('m1', 'u1', 'c1', 'user', 'text', '活着', 'sent', 'user', 100)
            """)
            try db.execute(sql: """
            INSERT INTO messages
                (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at, deleted_at)
            VALUES ('m2', 'u2', 'c1', 'user', 'text', '已删除', 'sent', 'user', 200, 5000)
            """)
        }

        inUseID = try await makeAttachment("sha-in-use", at: 300)
        staleID = try await makeAttachment("sha-stale", at: 300)
        orphanID = try await makeAttachment("sha-orphan", at: 100)

        try await attachments.link(messageID: "m1", attachmentID: inUseID, sort: 0)
        try await attachments.link(messageID: "m2", attachmentID: staleID, sort: 0)
    }

    private func makeAttachment(_ sha: String, at millis: Int64) async throws -> String {
        let record = try await attachments.ensure(
            NewAttachment(
                sha256: sha,
                kind: "image",
                relPath: "ab/cd/\(sha).png",
                byteSize: 1024,
                mime: "image/png",
                createdAt: millis
            )
        )
        return record.id
    }

    private func deletedAt(_ id: String) throws -> Int64? {
        try database.dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT deleted_at FROM attachments WHERE id = ?",
                arguments: [id]
            )
            return row.flatMap { Int64.fromDatabaseValue($0["deleted_at"]) }
        }
    }

    // MARK: - 引用

    func testReferencesCountsLiveAndStaleSeparately() async throws {
        let inUse = try await service.references(attachmentID: inUseID)
        XCTAssertEqual(inUse.totalReferences, 1)
        XCTAssertEqual(inUse.liveReferences, 1)
        XCTAssertTrue(inUse.isInUse)
        XCTAssertEqual(inUse.messageIDs, ["m1"])

        let stale = try await service.references(attachmentID: staleID)
        XCTAssertEqual(stale.totalReferences, 1)
        XCTAssertEqual(stale.liveReferences, 0, "已删除消息的关联属于陈旧引用")
        XCTAssertFalse(stale.isInUse)
    }

    func testReferencesMissingAttachmentThrows() async throws {
        do {
            _ = try await service.references(attachmentID: "missing")
            XCTFail("不存在的附件必须报错")
        } catch let error as AttachmentReferenceError {
            XCTAssertEqual(error, .notFound)
        }
    }

    // MARK: - 删除

    func testDeleteRefusesWhenInUse() async throws {
        do {
            try await service.deleteAttachment(id: inUseID, at: 9000, force: false)
            XCTFail("被活消息引用时必须拒绝删除")
        } catch let error as AttachmentReferenceError {
            XCTAssertEqual(error, .inUse(messageIDs: ["m1"]))
        }
        XCTAssertNil(try deletedAt(inUseID), "拒绝删除时不得改动附件")
    }

    func testForceDeleteUnlinksThenSoftDeletes() async throws {
        try await service.deleteAttachment(id: inUseID, at: 9000, force: true)
        XCTAssertEqual(try deletedAt(inUseID), 9000)

        let remaining = try await attachments.messageIDs(usingAttachment: inUseID)
        XCTAssertTrue(remaining.isEmpty, "强制删除必须解除全部关联")
    }

    func testDeleteUnreferencedAttachmentSucceeds() async throws {
        try await service.deleteAttachment(id: orphanID, at: 9000, force: false)
        XCTAssertEqual(try deletedAt(orphanID), 9000)
    }

    func testDeleteIsIdempotentAndKeepsFirstTimestamp() async throws {
        try await service.deleteAttachment(id: orphanID, at: 9000, force: false)
        try await service.deleteAttachment(id: orphanID, at: 9500, force: false)
        XCTAssertEqual(try deletedAt(orphanID), 9000, "重复删除不得刷新首次删除时间")
    }

    // MARK: - 解除引用

    func testUnlinkAllClearsReferences() async throws {
        let removed = try await service.unlinkAll(attachmentID: inUseID)
        XCTAssertEqual(removed, 1)

        let reference = try await service.references(attachmentID: inUseID)
        XCTAssertEqual(reference.totalReferences, 0)
        XCTAssertFalse(reference.isInUse)
    }

    // MARK: - 批量清理

    func testCleanupSkipsInUseAndDeletesRest() async throws {
        let result = try await service.cleanup(attachmentIDs: [inUseID, staleID, orphanID], at: 9000)
        XCTAssertEqual(result.deleted, 2)
        XCTAssertEqual(result.skippedInUse, 1)

        XCTAssertNil(try deletedAt(inUseID))
        XCTAssertEqual(try deletedAt(staleID), 9000, "只有陈旧引用的附件可清理")
        XCTAssertEqual(try deletedAt(orphanID), 9000)
    }

    func testCleanupIsIdempotent() async throws {
        _ = try await service.cleanup(attachmentIDs: [inUseID, staleID, orphanID], at: 9000)
        let second = try await service.cleanup(attachmentIDs: [inUseID, staleID, orphanID], at: 9500)
        XCTAssertEqual(second.deleted, 0)
        XCTAssertEqual(second.skippedInUse, 1, "仍被引用的附件持续跳过")
    }

    func testCleanupCandidatesRespectThresholdAndReferences() async throws {
        let candidates = try await service.cleanupCandidates(before: 200, limit: 10)
        XCTAssertEqual(candidates.map(\.id), [orphanID], "有引用的与晚于阈值的都不算候选")
    }

    func testCleanupWithEmptyListIsNoOp() async throws {
        let result = try await service.cleanup(attachmentIDs: [], at: 9000)
        XCTAssertEqual(result.deleted, 0)
        XCTAssertEqual(result.skippedInUse, 0)
    }

    // MARK: - 附件库列表（D57 界面数据源）

    func testLibraryReturnsEachAttachmentWithReferenceCounts() async throws {
        let items = try await service.library(includeDeleted: false, limit: 50, offset: 0)
        XCTAssertEqual(items.count, 3, "未软删附件应全部出现")

        // 创建时间倒序：in-use(300) / stale(300) 按 id 升序，然后 orphan(100)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        XCTAssertEqual(byID[inUseID]?.liveReferences, 1)
        XCTAssertEqual(byID[inUseID]?.totalReferences, 1)
        XCTAssertTrue(byID[inUseID]?.isInUse ?? false)

        XCTAssertEqual(byID[staleID]?.liveReferences, 0)
        XCTAssertEqual(byID[staleID]?.totalReferences, 1)
        XCTAssertTrue(byID[staleID]?.hasStaleReferencesOnly ?? false)
        XCTAssertFalse(byID[staleID]?.isInUse ?? true)

        XCTAssertEqual(byID[orphanID]?.totalReferences, 0)
        XCTAssertFalse(byID[orphanID]?.hasStaleReferencesOnly ?? true)
        XCTAssertEqual(items.last?.id, orphanID, "最早的附件排在最后")
    }

    func testLibraryHidesDeletedByDefaultAndCanIncludeThem() async throws {
        try await service.deleteAttachment(id: orphanID, at: 9000, force: false)

        let visible = try await service.library(includeDeleted: false, limit: 50, offset: 0)
        XCTAssertFalse(visible.contains { $0.id == orphanID })

        let all = try await service.library(includeDeleted: true, limit: 50, offset: 0)
        XCTAssertTrue(all.contains { $0.id == orphanID })
    }

    func testLibrarySupportsPaging() async throws {
        let first = try await service.library(includeDeleted: false, limit: 2, offset: 0)
        let second = try await service.library(includeDeleted: false, limit: 2, offset: 2)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(second.count, 1)
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: Set(second.map(\.id))), "分页不得重复")
    }
}

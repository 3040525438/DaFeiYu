import XCTest
import GRDB
import DFCore
@testable import DFData

/// W8：记忆写入、去重、版本、归属、检索与按来源删除。
final class MemoryRepositoryTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var repo: GRDBMemoryRepository!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFMemory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        repo = GRDBMemoryRepository(database: database)
    }

    override func tearDownWithError() throws {
        repo = nil
        database = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func draft(
        title: String = "喜欢摄影",
        content: String = "用户喜欢拍海边照片",
        scope: MemoryScope = .user,
        dedupe: String? = nil,
        source: MemorySourceRef? = MemorySourceRef(sourceType: "message", sourceID: "m1", excerpt: "喜欢拍海边")
    ) -> MemoryDraft {
        MemoryDraft(
            title: title,
            content: content,
            scope: scope,
            dedupeKey: dedupe,
            sources: source.map { [$0] } ?? []
        )
    }

    func testInsertAndFetch() async throws {
        let record = try await repo.insert(draft(), at: 1000)
        XCTAssertEqual(record.scope, .user)
        XCTAssertEqual(record.version, 1)

        let loaded = try await repo.memory(id: record.id)
        XCTAssertEqual(loaded?.content, "用户喜欢拍海边照片")

        let sources = try await repo.sources(memoryID: record.id)
        XCTAssertEqual(sources.map(\.sourceID), ["m1"])
    }

    func testEmptyContentRejected() async throws {
        do {
            _ = try await repo.insert(draft(content: "   "), at: 1)
            XCTFail("空内容必须拒绝")
        } catch let error as MemoryError {
            XCTAssertEqual(error, .emptyContent)
        }
    }

    func testDedupeAddsSourceWithoutNewRow() async throws {
        let first = try await repo.insert(draft(dedupe: "hobby:photography"), at: 1000)
        let second = try await repo.insert(
            draft(
                dedupe: "hobby:photography",
                source: MemorySourceRef(sourceType: "message", sourceID: "m2", excerpt: "又提到摄影")
            ),
            at: 2000
        )
        XCTAssertEqual(first.id, second.id, "同一去重键不得产生第二行")

        let sources = try await repo.sources(memoryID: first.id)
        XCTAssertEqual(Set(sources.map(\.sourceID)), ["m1", "m2"])
        let total = try await repo.count(scope: nil)
        XCTAssertEqual(total, 1)
    }

    func testUpdateContentBumpsVersionAndKeepsHistory() async throws {
        let record = try await repo.insert(draft(), at: 1000)
        let updated = try await repo.updateContent(
            id: record.id,
            title: "喜欢摄影与海",
            content: "用户喜欢拍海边照片，也喜欢拍日落",
            changedBy: "user",
            reason: "补充细节",
            at: 2000
        )
        XCTAssertEqual(updated.version, 2)
        XCTAssertEqual(updated.updatedAt, 2000)

        let versions = try await repo.versions(memoryID: record.id)
        XCTAssertEqual(versions.map(\.version), [1, 2])
        XCTAssertEqual(versions[0].content, "用户喜欢拍海边照片")
        XCTAssertEqual(versions[1].changeReason, "补充细节")
    }

    func testSearchRespectsScopeAndUpdatedContent() async throws {
        let userMemory = try await repo.insert(draft(scope: .user), at: 1000)
        _ = try await repo.insert(
            draft(title: "她的观察", content: "她注意到用户总在深夜说话", scope: .selfScope),
            at: 1100
        )

        let all = try await repo.search(query: "海边", scope: nil, limit: 10)
        XCTAssertEqual(all.map(\.id), [userMemory.id])

        let selfScope = try await repo.search(query: "深夜", scope: .selfScope, limit: 10)
        XCTAssertEqual(selfScope.count, 1)

        let wrongScope = try await repo.search(query: "深夜", scope: .user, limit: 10)
        XCTAssertTrue(wrongScope.isEmpty)

        _ = try await repo.updateContent(
            id: userMemory.id, title: "喜欢摄影", content: "改成喜欢爬山",
            changedBy: "user", reason: "纠正", at: 3000
        )
        let oldHits = try await repo.search(query: "海边", scope: nil, limit: 10)
        XCTAssertTrue(oldHits.isEmpty, "旧正文不得继续被检索到")
        let newHits = try await repo.search(query: "爬山", scope: nil, limit: 10)
        XCTAssertEqual(newHits.map(\.id), [userMemory.id])
    }

    func testSetScopeMarksConfirmedAndReindexes() async throws {
        let record = try await repo.insert(draft(scope: .shared), at: 1000)
        XCTAssertEqual(record.classificationStatus, "confirmed")

        let shared = try await repo.insert(
            MemoryDraft(title: "共同经历", content: "一起看了一场电影", scope: .shared),
            at: 1100
        )
        try await repo.setScope(id: shared.id, scope: .selfScope, evidence: "用户确认这是 AI 的感受", at: 2000)

        let updated = try await repo.memory(id: shared.id)
        XCTAssertEqual(updated?.scope, .selfScope)
        XCTAssertEqual(updated?.classificationStatus, "confirmed")

        let hits = try await repo.search(query: "电影", scope: .selfScope, limit: 10)
        XCTAssertEqual(hits.map(\.id), [shared.id])
    }

    func testSetImportanceWritesHistory() async throws {
        let record = try await repo.insert(draft(), at: 1000)
        try await repo.setImportance(id: record.id, score: 0.9, source: "user", reason: "这是重要偏好", at: 2000)

        let updated = try await repo.memory(id: record.id)
        XCTAssertEqual(updated?.importanceScore, 0.9)

        let count = try await database.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM memory_importance_history WHERE memory_id = ?",
                arguments: [record.id]
            ) ?? -1
        }
        XCTAssertEqual(count, 1, "重要度变更必须留痕")

        // 越界分数必须夹取
        try await repo.setImportance(id: record.id, score: 5, source: "user", reason: "越界", at: 3000)
        let clamped = try await repo.memory(id: record.id)
        XCTAssertEqual(clamped?.importanceScore, 1.0)
    }

    func testSoftDeleteBySourceOnlyAffectsLinkedMemories() async throws {
        let linked = try await repo.insert(
            draft(source: MemorySourceRef(sourceType: "message", sourceID: "m1")), at: 1000
        )
        let other = try await repo.insert(
            draft(title: "另一条", content: "来自别处的记忆",
                  source: MemorySourceRef(sourceType: "message", sourceID: "m9")),
            at: 1100
        )

        let affected = try await repo.softDelete(sourceType: "message", sourceID: "m1", at: 2000)
        XCTAssertEqual(affected, 1)

        let deleted = try await repo.memory(id: linked.id)
        XCTAssertTrue(deleted?.isDeleted == true)
        let kept = try await repo.memory(id: other.id)
        XCTAssertFalse(kept?.isDeleted ?? true)

        let hits = try await repo.search(query: "海边", scope: nil, limit: 10)
        XCTAssertTrue(hits.isEmpty)
    }

    func testRestoreReindexes() async throws {
        let record = try await repo.insert(draft(), at: 1000)
        try await repo.softDelete(id: record.id, at: 2000)
        try await repo.restore(id: record.id)

        let hits = try await repo.search(query: "海边", scope: nil, limit: 10)
        XCTAssertEqual(hits.map(\.id), [record.id])
        let restored = try await repo.memory(id: record.id)
        XCTAssertFalse(restored?.isDeleted ?? true)
    }

    func testListExcludesArchivedByDefault() async throws {
        let record = try await repo.insert(draft(), at: 1000)
        _ = try await repo.insert(draft(title: "第二条", content: "工作相关", scope: .shared), at: 1100)
        try await repo.archive(id: record.id, at: 2000)

        let active = try await repo.memories(scope: nil, layer: nil, includeArchived: false, limit: 50, offset: 0)
        XCTAssertEqual(active.count, 1)
        let all = try await repo.memories(scope: nil, layer: nil, includeArchived: true, limit: 50, offset: 0)
        XCTAssertEqual(all.count, 2)
    }

    func testCountByScope() async throws {
        _ = try await repo.insert(draft(), at: 1000)
        _ = try await repo.insert(draft(title: "共同", content: "一起经历", scope: .shared), at: 1100)
        _ = try await repo.insert(draft(title: "自我", content: "她的想法", scope: .selfScope), at: 1200)

        let totalCount = try await repo.count(scope: nil)
        XCTAssertEqual(totalCount, 3)
        let sharedCount = try await repo.count(scope: .shared)
        XCTAssertEqual(sharedCount, 1)
    }
}

import XCTest
import GRDB
import DFCore
@testable import DFData

/// 记忆链路自检（第九/十/十八条）：索引一致性、缺来源、重复、待确认。
final class MemoryHealthServiceTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var repository: GRDBMemoryRepository!
    private var service: MemoryHealthService!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFMemoryHealth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        repository = GRDBMemoryRepository(database: database)
        service = MemoryHealthService(database: database, now: { 1_700_000_000_000 })
    }

    override func tearDownWithError() throws {
        service = nil
        repository = nil
        database = nil
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testHealthyWhenIndexMatchesMemories() async throws {
        try await insert(title: "用户喜欢喝乌龙茶", dedupeKey: "tea")
        let report = try await service.check()
        XCTAssertEqual(report.active, 1)
        XCTAssertEqual(report.missingIndex, 0)
        XCTAssertEqual(report.orphanIndex, 0)
        XCTAssertTrue(report.isHealthy)
    }

    func testMissingIndexIsDetectedThenRepaired() async throws {
        try await insert(title: "约定每周日一起看纪录片", dedupeKey: "doc")
        try await insert(title: "用户养了一只叫团子的猫", dedupeKey: "cat")

        // 模拟"数据库已保存但索引丢失"
        try await database.write { db in
            try db.execute(sql: "DELETE FROM memory_fts")
        }
        var report = try await service.check()
        XCTAssertEqual(report.active, 2)
        XCTAssertEqual(report.missingIndex, 2)
        XCTAssertFalse(report.isHealthy)

        let repaired = try await service.repairIndex()
        XCTAssertEqual(repaired, 2)

        report = try await service.check()
        XCTAssertEqual(report.missingIndex, 0)
        XCTAssertEqual(report.indexed, 2)
        XCTAssertTrue(report.isHealthy)
    }

    func testOrphanIndexForDeletedMemoryIsCountedAndCleaned() async throws {
        try await insert(title: "用户下个月要搬家", dedupeKey: "move")
        let records = try await repository.memories(
            scope: nil, layer: nil, includeArchived: false, limit: 10, offset: 0
        )
        try await repository.softDelete(id: records[0].id, at: 1_700_000_001_000)
        // 软删会清索引；手动塞回一条孤儿索引，模拟异常路径
        try await database.write { db in
            try db.execute(
                sql: "INSERT INTO memory_fts (memory_id, scope, text_bigram) VALUES (?, 'shared', '搬家')",
                arguments: [records[0].id]
            )
        }

        let report = try await service.check()
        XCTAssertEqual(report.orphanIndex, 1)
        XCTAssertEqual(report.deleted, 1)

        _ = try await service.repairIndex()
        let cleaned = try await service.check()
        XCTAssertEqual(cleaned.orphanIndex, 0)
    }

    func testMemoryWithoutSourceIsReported() async throws {
        // 不带 sources：这条记忆无法追溯回原始内容
        _ = try await repository.insert(
            MemoryDraft(title: "无来源的推断", content: "用户可能喜欢下雨天", dedupeKey: "nosrc"),
            at: 1_700_000_000_000
        )
        try await insert(title: "有来源的事实", dedupeKey: "withsrc")

        let report = try await service.check()
        XCTAssertEqual(report.active, 2)
        XCTAssertEqual(report.withoutSource, 1)
    }

    func testDuplicateDedupeKeysAreReportedAsGroups() async throws {
        try await insert(title: "用户每天早上跑步", dedupeKey: "run")
        try await insert(title: "用户每天早上跑步", dedupeKey: "run-2")
        // 唯一索引保证正常运行不会写出重复 dedupe_key；这里模拟"历史库没有该索引"的情况
        try await database.write { db in
            try db.execute(sql: "DROP INDEX IF EXISTS ux_memories_dedupe")
            try db.execute(sql: "UPDATE memories SET dedupe_key = 'run' WHERE dedupe_key = 'run-2'")
        }

        let report = try await service.check()
        XCTAssertEqual(report.duplicateGroups, 1)
        XCTAssertFalse(report.isHealthy)
    }

    func testUnconfirmedStatusIsCounted() async throws {
        _ = try await repository.insert(
            MemoryDraft(
                title: "用户似乎不太喜欢吵闹的地方",
                content: "从几次聊天推断，用户偏好安静环境",
                epistemicStatus: "inferred",
                dedupeKey: "quiet"
            ),
            at: 1_700_000_000_000
        )
        let report = try await service.check()
        XCTAssertEqual(report.unconfirmed, 1)
    }

    // MARK: - 辅助

    @discardableResult
    private func insert(title: String, dedupeKey: String) async throws -> MemoryRecord {
        try await repository.insert(
            MemoryDraft(
                title: title,
                content: title,
                dedupeKey: dedupeKey,
                sources: [
                    MemorySourceRef(
                        sourceType: "message",
                        sourceID: "msg-\(dedupeKey)",
                        excerpt: title,
                        at: 1_700_000_000_000
                    )
                ]
            ),
            at: 1_700_000_000_000
        )
    }
}

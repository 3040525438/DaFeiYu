import XCTest
import GRDB
import DFCore
@testable import DFData

/// W6-7 / W6-5：每日日记、版本留档、全文检索与软删重建。
final class DiaryTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var repo: GRDBDiaryRepository!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFDiary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        repo = GRDBDiaryRepository(database: database)
    }

    override func tearDownWithError() throws {
        repo = nil
        database = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func request(
        _ date: String,
        content: String = "今天和她聊了很久",
        title: String = "晴",
        changedBy: String = "user",
        reason: String = ""
    ) -> DiaryUpsert {
        DiaryUpsert(
            entryDate: date, title: title, content: content,
            source: "manual", changedBy: changedBy, changeReason: reason
        )
    }

    func testCreateWritesVersionOne() async throws {
        let entry = try await repo.upsert(request("2026-11-15"), at: 1000)
        XCTAssertEqual(entry.entryDate, "2026-11-15")
        XCTAssertEqual(entry.title, "晴")

        let versions = try await repo.versions(diaryID: entry.id)
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions[0].version, 1)
        XCTAssertEqual(versions[0].content, "今天和她聊了很久")
    }

    func testUpdateAppendsVersionAndKeepsHistory() async throws {
        let entry = try await repo.upsert(request("2026-11-15"), at: 1000)
        _ = try await repo.upsert(
            request("2026-11-15", content: "改成了新的内容", reason: "补充细节", changedBy: "ai"),
            at: 2000
        )

        let current = try await repo.entry(date: "2026-11-15")
        XCTAssertEqual(current?.content, "改成了新的内容")
        XCTAssertEqual(current?.updatedAt, 2000)

        let versions = try await repo.versions(diaryID: entry.id)
        XCTAssertEqual(versions.map(\.version), [1, 2], "每次编辑都必须留全量版本")
        XCTAssertEqual(versions[0].content, "今天和她聊了很久")
        XCTAssertEqual(versions[1].changedBy, "ai")
        XCTAssertEqual(versions[1].changeReason, "补充细节")
    }

    func testEmptyContentRejected() async throws {
        do {
            _ = try await repo.upsert(request("2026-11-15", content: "   "), at: 1)
            XCTFail("空白内容必须拒绝")
        } catch let error as DiaryError {
            XCTAssertEqual(error, .emptyContent)
        }
    }

    func testInvalidDateRejected() async throws {
        for bad in ["2026-11-15x", "2026-13-01", "2026-02-30", "26-1-1"] {
            do {
                _ = try await repo.upsert(request(bad), at: 1)
                XCTFail("非法日期必须拒绝：\(bad)")
            } catch let error as DiaryError {
                XCTAssertEqual(error, .invalidDate(bad))
            }
        }
    }

    func testInvalidEditorRejected() async throws {
        do {
            _ = try await repo.upsert(request("2026-11-15", changedBy: "system"), at: 1)
            XCTFail("非法编辑者必须拒绝")
        } catch let error as DiaryError {
            XCTAssertEqual(error, .invalidEditor("system"))
        }
    }

    func testSoftDeleteAllowsRecreateSameDay() async throws {
        let first = try await repo.upsert(request("2026-11-15"), at: 1000)
        try await repo.softDelete(id: first.id, at: 2000)
        let deleted = try await repo.entry(date: "2026-11-15")
        XCTAssertNil(deleted)

        let second = try await repo.upsert(request("2026-11-15", content: "重新写"), at: 3000)
        XCTAssertNotEqual(second.id, first.id)

        let versions = try await repo.versions(diaryID: second.id)
        XCTAssertEqual(versions.map(\.version), [1], "重建后的日记版本从 1 开始")
    }

    func testEntriesRangeDescending() async throws {
        for date in ["2026-11-13", "2026-11-14", "2026-11-15"] {
            _ = try await repo.upsert(request(date), at: 1000)
        }
        let list = try await repo.entries(from: "2026-11-13", to: "2026-11-15", limit: 10)
        XCTAssertEqual(list.map(\.entryDate), ["2026-11-15", "2026-11-14", "2026-11-13"])
    }

    func testSearchFollowsLatestContentAndHidesDeleted() async throws {
        let entry = try await repo.upsert(request("2026-11-15", content: "明天去看摄影展"), at: 1000)
        var hits = try await repo.search(query: "摄影展", limit: 10)
        XCTAssertEqual(hits, [entry.id])

        _ = try await repo.upsert(request("2026-11-15", content: "改去看电影", reason: "计划变化"), at: 2000)
        hits = try await repo.search(query: "摄影展", limit: 10)
        XCTAssertTrue(hits.isEmpty, "旧内容不得继续被检索到")
        let movieHits = try await repo.search(query: "电影", limit: 10)
        XCTAssertEqual(movieHits, [entry.id])

        try await repo.softDelete(id: entry.id, at: 3000)
        let afterDelete = try await repo.search(query: "电影", limit: 10)
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testRebuildIndexCountsActiveEntries() async throws {
        _ = try await repo.upsert(request("2026-11-14", content: "第一篇"), at: 1000)
        let second = try await repo.upsert(request("2026-11-15", content: "第二篇"), at: 2000)
        try await repo.softDelete(id: second.id, at: 3000)

        let count = try await repo.rebuildIndex()
        XCTAssertEqual(count, 1, "软删日记不进入索引")

        let hits = try await repo.search(query: "第一篇", limit: 10)
        XCTAssertEqual(hits.count, 1)
    }
}

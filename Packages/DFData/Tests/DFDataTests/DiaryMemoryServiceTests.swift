import XCTest
import DFCore
@testable import DFData

/// W8-2 / D35：日记沉淀为长期记忆。
final class DiaryMemoryServiceTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var diary: GRDBDiaryRepository!
    private var memories: GRDBMemoryRepository!
    private var processing: MemoryProcessingService!
    private var service: DiaryMemoryService!
    private let now: Int64 = 2_000_000

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFDiaryMemory-\(UUID().uuidString)", isDirectory: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        diary = GRDBDiaryRepository(database: database)
        memories = GRDBMemoryRepository(database: database)
        processing = MemoryProcessingService(database: database, now: { self.now })
        service = DiaryMemoryService(diary: diary, processing: processing)
    }

    override func tearDownWithError() throws {
        service = nil
        processing = nil
        memories = nil
        diary = nil
        database = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - 沉淀

    func testDistillWritesMemoryAndAttachesToDiary() async throws {
        let entry = try await diary.upsert(
            DiaryUpsert(
                entryDate: "2026-11-15",
                title: "河边散步",
                content: "今天下午和她一起去河边公园散步，她说风很舒服。\n回来的路上买了热的豆花。",
                changedBy: "user"
            ),
            at: now
        )

        let outcome = try await service.distill(entryID: entry.id, at: now + 1)
        guard case let .distilled(memoryIDs, proposalIDs) = outcome else {
            return XCTFail("应沉淀成功，实际：\(outcome)")
        }
        XCTAssertEqual(memoryIDs.count, 1)
        XCTAssertTrue(proposalIDs.isEmpty)

        let memoryID = try XCTUnwrap(memoryIDs.first)
        // XCTUnwrap 的 autoclosure 不能放 await，先取值再解包
        let maybeRefreshed = try await diary.entry(id: entry.id)
        let refreshed = try XCTUnwrap(maybeRefreshed)
        XCTAssertEqual(refreshed.memoryID, memoryID)

        let maybeRecord = try await memories.memory(id: memoryID)
        let record = try XCTUnwrap(maybeRecord)
        XCTAssertEqual(record.layer, "episodic")
        XCTAssertEqual(record.scope, .shared)

        let sources = try await memories.sources(memoryID: memoryID)
        XCTAssertEqual(sources.count, 1, "日记来源要能指回")
        XCTAssertTrue(sources[0].sourceID.hasPrefix("diary:"))
    }

    func testDistillSkipsAlreadyDistilledEntry() async throws {
        let entry = try await diary.upsert(
            DiaryUpsert(entryDate: "2026-11-14", content: "今天学会了做番茄炒蛋。", changedBy: "user"),
            at: now
        )
        let first = try await service.distill(entryID: entry.id, at: now + 1)
        guard case let .distilled(memoryIDs, _) = first else {
            return XCTFail("首次应沉淀成功，实际：\(first)")
        }
        let memoryID = try XCTUnwrap(memoryIDs.first)

        let second = try await service.distill(entryID: entry.id, at: now + 2)
        XCTAssertEqual(second, .alreadyDistilled(memoryID))
    }

    func testDistillRejectsMissingOrDeletedEntry() async throws {
        do {
            _ = try await service.distill(entryID: "missing", at: now)
            XCTFail("不存在的日记应抛 notFound")
        } catch {
            XCTAssertEqual(error as? DiaryError, .notFound)
        }

        let entry = try await diary.upsert(
            DiaryUpsert(entryDate: "2026-11-13", content: "今天很安静。", changedBy: "user"),
            at: now
        )
        try await diary.softDelete(id: entry.id, at: now + 1)

        do {
            _ = try await service.distill(entryID: entry.id, at: now + 2)
            XCTFail("已删除的日记应抛 notFound")
        } catch {
            XCTAssertEqual(error as? DiaryError, .notFound)
        }
    }

    // MARK: - 纯函数

    func testFirstParagraphTrimsAndLimits() {
        let text = "\n  第一段内容  \n第二段内容"
        XCTAssertEqual(DiaryMemoryService.firstParagraph(of: text, limit: 50), "第一段内容")

        let long = String(repeating: "字", count: 100)
        XCTAssertEqual(DiaryMemoryService.firstParagraph(of: long, limit: 10).count, 10)
    }

    func testTitleFallsBackToEntryDate() {
        let entry = DiaryEntry(
            id: "d1",
            entryDate: "2026-11-15",
            title: "   ",
            content: "内容",
            moodCode: nil,
            source: "manual",
            generatedBy: nil,
            isUserEdited: false,
            memoryID: nil,
            createdAt: now,
            updatedAt: now,
            deletedAt: nil
        )
        XCTAssertEqual(DiaryMemoryService.title(for: entry), "2026-11-15")
    }
}

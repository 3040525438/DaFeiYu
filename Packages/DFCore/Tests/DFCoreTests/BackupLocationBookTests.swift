import XCTest
@testable import DFCore

/// D41：外部备份位置清单——去重、上限、迁移与多位置结果文案。
final class BackupLocationBookTests: XCTestCase {

    private func location(_ name: String, bookmark: String = "bm", id: String = UUID().uuidString) -> BackupLocation {
        BackupLocation(id: id, name: name, bookmarkBase64: bookmark)
    }

    // MARK: - 编解码

    func testEncodeDecodeRoundTrip() {
        let items = [location("iCloud Drive", bookmark: "a"), location("坚果云", bookmark: "b")]
        XCTAssertEqual(BackupLocationBook.decode(BackupLocationBook.encode(items)), items)
    }

    func testDecodeRejectsGarbage() {
        XCTAssertEqual(BackupLocationBook.decode(nil), [])
        XCTAssertEqual(BackupLocationBook.decode(""), [])
        XCTAssertEqual(BackupLocationBook.decode("not-json"), [])
        XCTAssertEqual(BackupLocationBook.decode("{}"), [])
    }

    func testDecodeDropsIncompleteEntries() {
        let json = """
        [{"id":"1","name":"ok","bookmarkBase64":"x"},
         {"id":"","name":"no-id","bookmarkBase64":"y"},
         {"id":"2","name":"no-bookmark","bookmarkBase64":""}]
        """
        let items = BackupLocationBook.decode(json)
        XCTAssertEqual(items.map(\.name), ["ok"])
    }

    // MARK: - 去重与上限

    func testUpsertReplacesSameName() {
        let first = location("iCloud Drive", bookmark: "a", id: "1")
        let second = location("iCloud Drive", bookmark: "b", id: "2")
        let result = BackupLocationBook.upserting(second, into: [first])
        XCTAssertEqual(result.map(\.id), ["2"])
    }

    func testUpsertReplacesSameBookmark() {
        let first = location("旧名字", bookmark: "same", id: "1")
        let second = location("新名字", bookmark: "same", id: "2")
        let result = BackupLocationBook.upserting(second, into: [first])
        XCTAssertEqual(result.map(\.name), ["新名字"])
    }

    func testUpsertKeepsDistinctLocations() {
        let a = location("A", bookmark: "a")
        let b = location("B", bookmark: "b")
        XCTAssertEqual(BackupLocationBook.upserting(b, into: [a]).count, 2)
    }

    func testUpsertDropsOldestWhenFull() {
        let items = (1...BackupLocationBook.maxCount).map { location("L\($0)", bookmark: "b\($0)") }
        let newcomer = location("新位置", bookmark: "new")
        let result = BackupLocationBook.upserting(newcomer, into: items)
        XCTAssertEqual(result.count, BackupLocationBook.maxCount)
        XCTAssertEqual(result.last?.name, "新位置")
        XCTAssertFalse(result.contains { $0.name == "L1" }, "超上限时丢弃最早的位置")
    }

    func testIsFull() {
        let items = (1...BackupLocationBook.maxCount).map { location("L\($0)", bookmark: "b\($0)") }
        XCTAssertTrue(BackupLocationBook.isFull(items))
        XCTAssertFalse(BackupLocationBook.isFull(Array(items.prefix(1))))
    }

    func testRemoving() {
        let a = location("A", bookmark: "a", id: "1")
        let b = location("B", bookmark: "b", id: "2")
        XCTAssertEqual(BackupLocationBook.removing(id: "1", from: [a, b]).map(\.id), ["2"])
        XCTAssertEqual(BackupLocationBook.removing(id: "missing", from: [a, b]).count, 2)
    }

    // MARK: - 旧版迁移

    func testMigratesLegacySingleLocation() {
        let items = BackupLocationBook.migrating(legacyBookmark: "old-bookmark", legacyName: "iCloud Drive")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.name, "iCloud Drive")
        XCTAssertEqual(items.first?.bookmarkBase64, "old-bookmark")
    }

    func testMigrationWithoutLegacyIsEmpty() {
        XCTAssertTrue(BackupLocationBook.migrating(legacyBookmark: nil, legacyName: "x").isEmpty)
        XCTAssertTrue(BackupLocationBook.migrating(legacyBookmark: "  ", legacyName: "x").isEmpty)
    }

    func testMigrationFallsBackToGenericName() {
        let items = BackupLocationBook.migrating(legacyBookmark: "bm", legacyName: nil)
        XCTAssertEqual(items.first?.name, "外部目录")
    }

    // MARK: - 结果文案

    func testSummaryAllSucceeded() {
        let results = [
            BackupMirrorResult(locationID: "1", locationName: "iCloud", succeeded: true, detail: ""),
            BackupMirrorResult(locationID: "2", locationName: "坚果云", succeeded: true, detail: "")
        ]
        XCTAssertEqual(BackupMirrorSummary.text(for: results), "已复制到 2 个外部位置：iCloud、坚果云")
    }

    func testSummaryPartialFailure() {
        let results = [
            BackupMirrorResult(locationID: "1", locationName: "iCloud", succeeded: true, detail: ""),
            BackupMirrorResult(locationID: "2", locationName: "坚果云", succeeded: false, detail: "授权失效")
        ]
        let text = BackupMirrorSummary.text(for: results)
        XCTAssertTrue(text.contains("成功 1 / 共 2"))
        XCTAssertTrue(text.contains("坚果云（授权失效）"))
    }

    func testSummaryAllFailed() {
        let results = [
            BackupMirrorResult(locationID: "1", locationName: "iCloud", succeeded: false, detail: "书签失效")
        ]
        XCTAssertEqual(BackupMirrorSummary.text(for: results), "全部失败：iCloud（书签失效）")
    }

    func testSummaryEmpty() {
        XCTAssertEqual(BackupMirrorSummary.text(for: []), "还没有可用的外部位置")
    }
}

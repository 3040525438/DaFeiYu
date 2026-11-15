import XCTest
@testable import DFCore

/// D59：数据流向目录——内容完整性与一致性。
final class DataFlowCatalogTests: XCTestCase {
    func testSummaryCountsMatchEntries() {
        let categories = DataFlowCatalog.categories()
        XCTAssertEqual(categories.count, Set(categories).count, "分类不得重复")
        XCTAssertEqual(categories.count, 9)
        XCTAssertTrue(DataFlowCatalog.summary.contains("\(categories.count) 类数据"))
        XCTAssertTrue(DataFlowCatalog.summary.contains("\(DataFlowCatalog.leavingDeviceCount) 类可能离开设备"))
    }

    func testLeavingDeviceEntriesAreExactlyTheUploadPaths() {
        let ids = DataFlowCatalog.entries.filter { $0.destination.leavesDevice }.map(\.id).sorted()
        XCTAssertEqual(ids, ["attachment.cloud", "backup", "chat.cloud", "diagnostics"])
        XCTAssertEqual(DataFlowCatalog.leavingDeviceCount, ids.count)
    }

    func testEveryEntryIsComplete() {
        for entry in DataFlowCatalog.entries {
            XCTAssertFalse(entry.id.isEmpty)
            XCTAssertFalse(entry.title.isEmpty, "\(entry.id) 缺标题")
            XCTAssertFalse(entry.contents.isEmpty, "\(entry.id) 缺内容说明")
            XCTAssertFalse(entry.revokeHint.isEmpty, "\(entry.id) 缺撤销说明")
            XCTAssertFalse(entry.controlHint.isEmpty, "\(entry.id) 缺控制入口")
        }
    }

    func testEntryIDsAreUnique() {
        let ids = DataFlowCatalog.entries.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testEntriesInCategory() {
        let chat = DataFlowCatalog.entries(in: "聊天")
        XCTAssertEqual(chat.count, 2)
        XCTAssertTrue(chat.allSatisfy { $0.category == "聊天" })
        XCTAssertTrue(DataFlowCatalog.entries(in: "不存在的分类").isEmpty)
    }

    func testDestinationDisplayNames() {
        XCTAssertEqual(DataFlowDestination.onDevice.displayName, "仅本机")
        XCTAssertFalse(DataFlowDestination.onDevice.leavesDevice)
        XCTAssertTrue(DataFlowDestination.cloudModel.leavesDevice)
        XCTAssertTrue(DataFlowDestination.userChosenLocation.leavesDevice)
    }
}

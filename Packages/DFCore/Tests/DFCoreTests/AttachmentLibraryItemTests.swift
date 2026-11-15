import XCTest
@testable import DFCore

/// D57：附件库列表项的引用状态判定。
final class AttachmentLibraryItemTests: XCTestCase {
    private func record(_ id: String) -> AttachmentRecord {
        AttachmentRecord(
            id: id,
            sha256: "sha-\(id)",
            kind: "image",
            relPath: "ab/cd/\(id).png",
            byteSize: 2048,
            mime: "image/png",
            createdAt: 1000
        )
    }

    func testLiveReferencesMeanInUse() {
        let item = AttachmentLibraryItem(record: record("a"), totalReferences: 2, liveReferences: 1)
        XCTAssertTrue(item.isInUse)
        XCTAssertFalse(item.hasStaleReferencesOnly)
    }

    func testOnlyStaleReferencesIsNotInUseButFlagged() {
        let item = AttachmentLibraryItem(record: record("b"), totalReferences: 2, liveReferences: 0)
        XCTAssertFalse(item.isInUse, "只有已删除消息的关联，不应视为使用中")
        XCTAssertTrue(item.hasStaleReferencesOnly)
    }

    func testUnreferencedAttachmentHasNoFlags() {
        let item = AttachmentLibraryItem(record: record("c"), totalReferences: 0, liveReferences: 0)
        XCTAssertFalse(item.isInUse)
        XCTAssertFalse(item.hasStaleReferencesOnly)
        XCTAssertEqual(item.id, "c")
    }
}

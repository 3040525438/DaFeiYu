import XCTest
@testable import DFCore

/// A1 · P 系列与 R 系列（校验部分）：白名单、会话归属、存在性与上限
final class ReferenceProtocolTests: XCTestCase {

    // MARK: - P01 协议片段

    func testP01_SystemFragmentContents() {
        let fragment = ReferenceProtocol.systemFragment
        XCTAssertTrue(fragment.contains(StreamingReferenceParser.tagOpen))
        XCTAssertTrue(fragment.contains("最多 3 条"))
        XCTAssertTrue(fragment.contains("可选"))
        XCTAssertFalse(fragment.isEmpty)
    }

    // MARK: - R08 白名单外

    func testR08_OutsideWhitelistDropped() {
        let result = ReferenceProtocol.validate(.init(
            citations: ["m-out"],
            allowed: ["m1"],
            existingConversationMap: ["m-out": "c1", "m1": "c1"],
            conversationID: "c1"
        ))
        XCTAssertEqual(result.kept, [])
        XCTAssertEqual(result.droppedUnknown, 1)
    }

    // MARK: - R10 跨会话

    func testR10_CrossConversationDropped() {
        let result = ReferenceProtocol.validate(.init(
            citations: ["m-other"],
            allowed: ["m-other"],
            existingConversationMap: ["m-other": "c2"],
            conversationID: "c1"
        ))
        XCTAssertEqual(result.kept, [])
        XCTAssertEqual(result.droppedCrossConversation, 1)
    }

    // MARK: - R11 不存在的 id

    func testR11_UnknownIDDropped() {
        let result = ReferenceProtocol.validate(.init(
            citations: ["ghost"],
            allowed: ["ghost"],
            existingConversationMap: [:],
            conversationID: "c1"
        ))
        XCTAssertEqual(result.kept, [])
        XCTAssertEqual(result.droppedUnknown, 1)
    }

    // MARK: - R13 已软删

    func testR13_DeletedTargetDropped() {
        let result = ReferenceProtocol.validate(.init(
            citations: ["m-deleted"],
            allowed: ["m-deleted"],
            existingConversationMap: [:],
            deletedIDs: ["m-deleted"],
            conversationID: "c1"
        ))
        XCTAssertEqual(result.kept, [])
        XCTAssertEqual(result.droppedDeleted, 1)
    }

    // MARK: - 去重与上限

    func testDeduplicatesPreservingOrder() {
        let result = ReferenceProtocol.validate(.init(
            citations: ["m2", "m1", "m2", "m3"],
            allowed: ["m1", "m2", "m3"],
            existingConversationMap: ["m1": "c1", "m2": "c1", "m3": "c1"],
            conversationID: "c1"
        ))
        XCTAssertEqual(result.kept, ["m2", "m1", "m3"])
        XCTAssertEqual(result.droppedOverLimit, 0)
    }

    func testOverLimitTruncatedBeforeValidation() {
        let result = ReferenceProtocol.validate(.init(
            citations: ["m1", "m2", "m3", "m4"],
            allowed: ["m1", "m2", "m3", "m4"],
            existingConversationMap: ["m1": "c1", "m2": "c1", "m3": "c1", "m4": "c1"],
            conversationID: "c1"
        ))
        XCTAssertEqual(result.kept, ["m1", "m2", "m3"])
        XCTAssertEqual(result.droppedOverLimit, 1)
    }

    func testMixedCasesReportedSeparately() {
        // 上限（3）优先于分类校验：4 条输入先被截断，末位不参与后续分类
        let truncated = ReferenceProtocol.validate(.init(
            citations: ["ok", "other", "ghost", "deleted"],
            allowed: ["ok", "other", "ghost", "deleted"],
            existingConversationMap: ["ok": "c1", "other": "c2", "deleted": "c1"],
            deletedIDs: ["deleted"],
            conversationID: "c1"
        ))
        XCTAssertEqual(truncated.kept, ["ok"])
        XCTAssertEqual(truncated.droppedCrossConversation, 1)
        XCTAssertEqual(truncated.droppedUnknown, 1)
        XCTAssertEqual(truncated.droppedDeleted, 0, "第 4 条已被上限截断，不该归入已删")
        XCTAssertEqual(truncated.droppedOverLimit, 1)

        // 3 条以内：跨会话 / 已删 各自归类，互不吞并
        let mixed = ReferenceProtocol.validate(.init(
            citations: ["ok", "other", "deleted"],
            allowed: ["ok", "other", "deleted"],
            existingConversationMap: ["ok": "c1", "other": "c2", "deleted": "c1"],
            deletedIDs: ["deleted"],
            conversationID: "c1"
        ))
        XCTAssertEqual(mixed.kept, ["ok"])
        XCTAssertEqual(mixed.droppedCrossConversation, 1)
        XCTAssertEqual(mixed.droppedDeleted, 1)
        XCTAssertEqual(mixed.droppedOverLimit, 0)
    }
}

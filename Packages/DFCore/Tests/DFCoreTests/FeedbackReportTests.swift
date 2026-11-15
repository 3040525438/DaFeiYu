import XCTest
@testable import DFCore

/// D70 / D53：反馈报告只含版本与计数、描述截断、隐私声明固定。
final class FeedbackReportTests: XCTestCase {

    private let snapshot = DiagnosticsSnapshot(
        appVersion: "2.0.0",
        buildNumber: "102",
        systemVersion: "iOS 17.2",
        schemaVersion: "v14_message_organization",
        messageCount: 123,
        attachmentCount: 4,
        memoryCount: 56
    )

    func testReportContainsVersionsAndCounts() {
        let report = FeedbackReportBuilder.make(category: .bug, detail: "点发送没反应", snapshot: snapshot)
        XCTAssertEqual(report.category, .bug)
        XCTAssertTrue(report.body.contains("功能异常"))
        XCTAssertTrue(report.body.contains("v2.0.0 (102)"))
        XCTAssertTrue(report.body.contains("iOS 17.2"))
        XCTAssertTrue(report.body.contains("v14_message_organization"))
        XCTAssertTrue(report.body.contains("消息：123 条"))
        XCTAssertTrue(report.body.contains("附件：4 个"))
        XCTAssertTrue(report.body.contains("记忆：56 条"))
        XCTAssertTrue(report.body.contains("点发送没反应"))
    }

    func testPrivacyNoticeAlwaysPresent() {
        let report = FeedbackReportBuilder.make(category: .other, detail: "", snapshot: snapshot)
        XCTAssertTrue(report.body.contains(FeedbackReportBuilder.privacyNotice))
        XCTAssertTrue(report.body.contains("（未填写）"))
    }

    func testDetailIsTrimmedAndTruncated() {
        let long = "  " + String(repeating: "a", count: FeedbackReportBuilder.maxDetailLength + 50) + "  "
        let report = FeedbackReportBuilder.make(category: .suggestion, detail: long, snapshot: snapshot)
        XCTAssertFalse(report.body.contains(String(repeating: "a", count: FeedbackReportBuilder.maxDetailLength + 1)))
        XCTAssertTrue(report.body.contains(String(repeating: "a", count: FeedbackReportBuilder.maxDetailLength)))
    }

    func testMissingCountsAreOmittedNotFaked() {
        let partial = DiagnosticsSnapshot(
            appVersion: "2.0.0",
            buildNumber: "",
            systemVersion: "",
            schemaVersion: ""
        )
        let text = FeedbackReportBuilder.diagnosticsText(partial)
        XCTAssertEqual(text, "App：v2.0.0")
        XCTAssertFalse(text.contains("消息："), "拿不到计数时不得写 0 或猜测")
    }

    func testAllCategoriesHaveDisplayName() {
        for category in FeedbackCategory.allCases {
            XCTAssertFalse(category.displayName.isEmpty)
        }
    }
}

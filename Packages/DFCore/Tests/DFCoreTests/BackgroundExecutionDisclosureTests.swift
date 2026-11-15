import XCTest
@testable import DFCore

/// D21：后台任务不承诺准点，成本与隐私说明必须如实。
final class BackgroundExecutionDisclosureTests: XCTestCase {

    func testTimingIsNeverGuaranteed() {
        XCTAssertFalse(BackgroundExecutionPolicy.timingGuaranteed)
        XCTAssertTrue(BackgroundExecutionPolicy.disclosure.timing.contains("不保证"))
    }

    func testDisclosureCoversCostAndPrivacy() {
        let disclosure = BackgroundExecutionPolicy.disclosure
        XCTAssertFalse(disclosure.whatRuns.isEmpty)
        XCTAssertTrue(disclosure.cost.contains("费用"))
        XCTAssertTrue(disclosure.privacy.contains("不会上传"))
        XCTAssertTrue(disclosure.privacy.contains("最少上下文"))
    }

    func testNextRunExplanationWhenNothingScheduled() {
        XCTAssertEqual(
            BackgroundExecutionPolicy.nextRunExplanation(scheduledAt: nil, now: 1_000),
            "暂未安排下一次后台任务"
        )
    }

    func testOverdueStillNotGuaranteed() {
        let text = BackgroundExecutionPolicy.nextRunExplanation(scheduledAt: 900, now: 1_000)
        XCTAssertTrue(text.contains("可能延后"))
    }

    func testFutureRunExplanationIncludesEstimateAndCaveat() {
        let halfHour = BackgroundExecutionPolicy.nextRunExplanation(
            scheduledAt: 1_000 + 30 * 60_000,
            now: 1_000
        )
        XCTAssertTrue(halfHour.contains("30 分钟"))
        XCTAssertTrue(halfHour.contains("可能延后"))

        let threeHours = BackgroundExecutionPolicy.nextRunExplanation(
            scheduledAt: 1_000 + 180 * 60_000,
            now: 1_000
        )
        XCTAssertTrue(threeHours.contains("3 小时"))
    }
}

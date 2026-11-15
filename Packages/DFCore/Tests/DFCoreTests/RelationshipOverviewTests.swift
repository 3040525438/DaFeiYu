import XCTest
@testable import DFCore

/// D31：关系回顾纯逻辑（分组 / 排序 / 精度 / 空态）
final class RelationshipOverviewTests: XCTestCase {
    private let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    private func millis(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = hour
        parts.minute = minute
        let date = calendar.date(from: parts)!
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private func profile(
        stage: RelationshipStage = .unset,
        partnerName: String = "",
        summary: String = "",
        closeness: Double = 0.5,
        stageSince: Int64? = nil
    ) -> RelationshipProfile {
        RelationshipProfile(
            id: "primary",
            partnerName: partnerName,
            stage: stage,
            stageSince: stageSince,
            closeness: closeness,
            summary: summary,
            evidenceJSON: "[]",
            confirmedBy: nil,
            confirmedAt: nil,
            updatedAt: 1
        )
    }

    private func milestone(
        id: String,
        kind: RelationshipMilestoneKind,
        title: String,
        occurredAt: Int64,
        precision: RelationshipTimePrecision = .day,
        importance: String = "normal",
        source: RelationshipSourceKind = .userConfirmed
    ) -> RelationshipMilestone {
        RelationshipMilestone(
            id: id,
            kind: kind,
            title: title,
            summary: "",
            occurredAt: occurredAt,
            timePrecision: precision,
            importance: importance,
            memoryID: nil,
            episodeID: nil,
            sourceKind: source,
            status: "active",
            createdAt: occurredAt,
            updatedAt: occurredAt
        )
    }

    private func change(
        id: String,
        from: RelationshipStage,
        to: RelationshipStage,
        status: RelationshipStageChangeStatus,
        decidedBy: String = "ai",
        createdAt: Int64
    ) -> RelationshipStageChange {
        RelationshipStageChange(
            id: id,
            fromStage: from,
            toStage: to,
            reason: "证据充分",
            evidenceJSON: "[]",
            decidedBy: decidedBy,
            status: status,
            memoryID: nil,
            createdAt: createdAt,
            resolvedAt: status == .pending ? nil : createdAt
        )
    }

    // MARK: - 空态

    func testEmptyProfileShowsHintsWithoutInventingContent() {
        let overview = RelationshipOverview.compose(
            profile: profile(),
            milestones: [],
            stageChanges: [],
            timeZone: timeZone
        )
        XCTAssertEqual(overview.stageText, "未设定")
        XCTAssertTrue(overview.isStageUnset)
        XCTAssertEqual(overview.partnerNameText, "还没有设置昵称")
        XCTAssertEqual(overview.summaryText, "还没有写下你们的关系说明")
        XCTAssertEqual(overview.stageSinceText, "—")
        XCTAssertFalse(overview.hasAnyContent)
        XCTAssertEqual(overview.totalMilestones, 0)
        XCTAssertTrue(overview.emptyHint(in: .sharedExperience).contains("共同经历"))
    }

    func testProfileAloneCountsAsContent() {
        let overview = RelationshipOverview.compose(
            profile: profile(stage: .close, partnerName: "小鱼", summary: "异地但稳定"),
            milestones: [],
            stageChanges: [],
            timeZone: timeZone
        )
        XCTAssertTrue(overview.hasAnyContent)
        XCTAssertEqual(overview.stageText, "亲近")
        XCTAssertEqual(overview.partnerNameText, "小鱼")
        XCTAssertEqual(overview.summaryText, "异地但稳定")
        XCTAssertFalse(overview.isStageUnset)
    }

    // MARK: - 分组

    func testMilestonesAreGroupedByKind() {
        let overview = RelationshipOverview.compose(
            profile: profile(),
            milestones: [
                milestone(id: "m1", kind: .sharedExperience, title: "一起看海", occurredAt: millis(2026, 3, 1)),
                milestone(id: "m2", kind: .turningPoint, title: "第一次认真吵架", occurredAt: millis(2026, 5, 2)),
                milestone(id: "m3", kind: .anniversary, title: "相识一周年", occurredAt: millis(2026, 6, 3)),
                milestone(id: "m4", kind: .other, title: "随手记", occurredAt: millis(2026, 7, 4))
            ],
            stageChanges: [],
            timeZone: timeZone
        )
        XCTAssertEqual(overview.sharedExperience.map(\.id), ["m1"])
        XCTAssertEqual(overview.turningPoint.map(\.id), ["m2"])
        XCTAssertEqual(overview.anniversary.map(\.id), ["m3"])
        XCTAssertEqual(overview.otherMilestones.map(\.id), ["m4"])
        XCTAssertEqual(overview.totalMilestones, 4)
        XCTAssertEqual(overview.count(in: .overview), 4)
        XCTAssertEqual(overview.count(in: .anniversary), 1)
        XCTAssertTrue(overview.milestones(in: .overview).isEmpty)
    }

    func testMilestonesSortedNewestFirst() {
        let overview = RelationshipOverview.compose(
            profile: profile(),
            milestones: [
                milestone(id: "old", kind: .sharedExperience, title: "春天", occurredAt: millis(2026, 1, 1)),
                milestone(id: "new", kind: .sharedExperience, title: "秋天", occurredAt: millis(2026, 10, 1)),
                milestone(id: "mid", kind: .sharedExperience, title: "夏天", occurredAt: millis(2026, 6, 1))
            ],
            stageChanges: [],
            timeZone: timeZone
        )
        XCTAssertEqual(overview.sharedExperience.map(\.id), ["new", "mid", "old"])
    }

    // MARK: - 精度

    func testDateTextNeverFakesPrecision() {
        let stamp = millis(2026, 11, 15, 10, 30)
        XCTAssertEqual(
            RelationshipDateText.text(millis: stamp, precision: .exact, timeZone: timeZone),
            "2026-11-15 10:30"
        )
        XCTAssertEqual(
            RelationshipDateText.text(millis: stamp, precision: .day, timeZone: timeZone),
            "2026-11-15"
        )
        XCTAssertEqual(
            RelationshipDateText.text(millis: stamp, precision: .month, timeZone: timeZone),
            "2026年11月"
        )
        XCTAssertEqual(
            RelationshipDateText.text(millis: stamp, precision: .year, timeZone: timeZone),
            "2026年"
        )
    }

    func testInvalidTimestampFallsBackToUnknown() {
        XCTAssertEqual(
            RelationshipDateText.text(millis: 0, precision: .day, timeZone: timeZone),
            "时间未知"
        )
    }

    // MARK: - 文案

    func testClosenessIsClampedAndRounded() {
        XCTAssertEqual(RelationshipOverview.closenessText(0.876), "88%")
        XCTAssertEqual(RelationshipOverview.closenessText(-1), "0%")
        XCTAssertEqual(RelationshipOverview.closenessText(2), "100%")
        XCTAssertEqual(RelationshipOverview.closenessText(.nan), "0%")
    }

    func testOverviewExposesClampedClosenessForProgressBar() {
        let overview = RelationshipOverview.compose(
            profile: profile(closeness: 1.4),
            milestones: [],
            stageChanges: [],
            timeZone: timeZone
        )
        XCTAssertEqual(overview.closeness, 1)
        XCTAssertEqual(overview.closenessText, "100%")
    }

    func testImportanceText() {
        XCTAssertEqual(RelationshipOverview.importanceText("high"), "重要")
        XCTAssertEqual(RelationshipOverview.importanceText("low"), "次要")
        XCTAssertEqual(RelationshipOverview.importanceText("normal"), "一般")
        XCTAssertEqual(RelationshipOverview.importanceText("unknown"), "一般")
    }

    func testHighlightedOnlyForHighImportance() {
        let overview = RelationshipOverview.compose(
            profile: profile(),
            milestones: [
                milestone(id: "h", kind: .turningPoint, title: "转折", occurredAt: millis(2026, 2, 2), importance: "high"),
                milestone(id: "n", kind: .turningPoint, title: "普通", occurredAt: millis(2026, 3, 3))
            ],
            stageChanges: [],
            timeZone: timeZone
        )
        XCTAssertEqual(overview.turningPoint.first { $0.id == "h" }?.isHighlighted, true)
        XCTAssertEqual(overview.turningPoint.first { $0.id == "n" }?.isHighlighted, false)
    }

    // MARK: - 阶段历史

    func testStageHistorySortedAndLocalized() {
        let overview = RelationshipOverview.compose(
            profile: profile(stage: .familiar),
            milestones: [],
            stageChanges: [
                change(id: "c1", from: .unset, to: .acquaintance, status: .approved, createdAt: millis(2026, 1, 1)),
                change(id: "c2", from: .acquaintance, to: .familiar, status: .approved, decidedBy: "user", createdAt: millis(2026, 4, 1)),
                change(id: "c3", from: .familiar, to: .close, status: .pending, createdAt: millis(2026, 6, 1)),
                change(id: "c4", from: .familiar, to: .stable, status: .rejected, createdAt: millis(2026, 5, 1))
            ],
            timeZone: timeZone
        )
        XCTAssertEqual(overview.stageHistory.map(\.id), ["c3", "c4", "c2", "c1"])
        XCTAssertEqual(overview.pendingProposalCount, 1)
        XCTAssertEqual(overview.stageHistory.first?.statusText, "待你确认")
        XCTAssertEqual(overview.stageHistory.first?.isPending, true)
        XCTAssertEqual(overview.stageHistory.first?.fromText, "熟悉")
        XCTAssertEqual(overview.stageHistory.first?.toText, "亲近")
        XCTAssertEqual(overview.stageHistory[2].proposerText, "你提出")
        XCTAssertEqual(overview.stageHistory[3].fromText, "未设定")
        XCTAssertEqual(overview.stageHistory[1].statusText, "已驳回")
    }

    func testStageSinceUsesDayPrecision() {
        let overview = RelationshipOverview.compose(
            profile: profile(
                stage: .close,
                stageSince: millis(2026, 9, 9, 21, 5)
            ),
            milestones: [],
            stageChanges: [],
            timeZone: timeZone
        )
        XCTAssertEqual(overview.stageSinceText, "2026-09-09")
    }

    func testSourceTextComesFromMilestoneSource() {
        let overview = RelationshipOverview.compose(
            profile: profile(),
            milestones: [
                milestone(
                    id: "m1",
                    kind: .sharedExperience,
                    title: "一起散步",
                    occurredAt: millis(2026, 2, 2),
                    source: .realInteraction
                )
            ],
            stageChanges: [],
            timeZone: timeZone
        )
        XCTAssertEqual(overview.sharedExperience.first?.sourceText, "真实互动")
    }

    func testEmptyHintForEachSection() {
        let overview = RelationshipOverview.compose(
            profile: profile(),
            milestones: [],
            stageChanges: [],
            timeZone: timeZone
        )
        XCTAssertFalse(overview.emptyHint(in: .stageHistory).isEmpty)
        XCTAssertTrue(overview.emptyHint(in: .turningPoint).contains("重要转折"))
        XCTAssertTrue(overview.emptyHint(in: .overview).contains("关系记录"))
    }
}

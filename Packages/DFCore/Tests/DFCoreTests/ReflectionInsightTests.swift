import XCTest
@testable import DFCore

/// D62：自主洞察的严格 Schema、证据逐字校验、置信度夹取与"必须用户确认"规则。
final class ReflectionInsightTests: XCTestCase {

    private let contextText = """
    用户：我最近在准备考试，压力有点大
    大肥鱼：那我陪你慢慢来
    用户：摄影课停了，改成每周自习
    """

    private func wrap(_ items: String) -> String {
        #"{"insights":[\#(items)]}"#
    }

    // MARK: - 严格 Schema

    func testStrictParseAcceptsAllFiveKinds() {
        let raw = wrap("""
        {"kind":"recall_recent","summary":"最近在准备考试","evidence":["我最近在准备考试"],"confidence":0.8,"target_memory_id":null},
        {"kind":"memory_link","summary":"考试与摄影课时间冲突","evidence":["摄影课停了"],"confidence":0.6,"target_memory_id":"mem1"},
        {"kind":"worth_recording","summary":"每周自习成为新习惯","evidence":["改成每周自习"],"confidence":0.55,"target_memory_id":null},
        {"kind":"stance_change","summary":"对摄影课的态度变淡","evidence":["摄影课停了"],"confidence":0.4,"target_memory_id":null},
        {"kind":"correction_proposal","summary":"旧记忆里的课程安排已过期","evidence":["改成每周自习"],"confidence":0.5,"target_memory_id":"mem2"}
        """)
        let result = ReflectionInsightParser.parse(raw)
        XCTAssertNil(result.failure)
        XCTAssertTrue(result.isStrict)
        XCTAssertEqual(result.insights.map(\.kind), ReflectionInsightKind.allCases)
        XCTAssertEqual(result.insights[0].confidence, 0.8, accuracy: 0.0001)
        XCTAssertNil(result.insights[0].targetMemoryID)
        XCTAssertEqual(result.insights[1].targetMemoryID, "mem1")
        XCTAssertEqual(result.insights[4].targetMemoryID, "mem2")
    }

    func testCodeFenceAcceptedWithoutLooseningSchema() {
        let raw = """
        ```json
        {"insights":[{"kind":"recall_recent","summary":"考试","evidence":["准备考试"],"confidence":0.5}]}
        ```
        """
        let result = ReflectionInsightParser.parse(raw)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.insights.count, 1)
    }

    func testEmptyInsightsArrayIsValid() {
        let result = ReflectionInsightParser.parse(#"{"insights":[]}"#)
        XCTAssertNil(result.failure)
        XCTAssertTrue(result.insights.isEmpty)
    }

    // MARK: - 异常输入

    func testEmptyOutputRejected() {
        let result = ReflectionInsightParser.parse("   \n ")
        XCTAssertEqual(result.failure, .emptyOutput)
        XCTAssertTrue(result.insights.isEmpty)
    }

    func testNonJSONRejected() {
        let result = ReflectionInsightParser.parse("我觉得她最近挺累的")
        XCTAssertEqual(result.failure, .notJSONObject)
    }

    func testUnknownTopLevelKeyRejected() {
        let result = ReflectionInsightParser.parse(#"{"insights":[],"note":"多出来的键"}"#)
        XCTAssertEqual(result.failure, .unknownKeys)
    }

    func testMissingInsightsKeyRejected() {
        let result = ReflectionInsightParser.parse(#"{"items":[]}"#)
        XCTAssertEqual(result.failure, .missingKeys)
    }

    func testUnknownItemKeyRejected() {
        let raw = wrap("""
        {"kind":"recall_recent","summary":"考试","evidence":["准备考试"],"confidence":0.5,"extra":1}
        """)
        XCTAssertEqual(ReflectionInsightParser.parse(raw).failure, .unknownKeys)
    }

    func testMissingItemKeyRejected() {
        let raw = wrap(#"{"kind":"recall_recent","summary":"考试","confidence":0.5}"#)
        XCTAssertEqual(ReflectionInsightParser.parse(raw).failure, .missingKeys)
    }

    func testUnknownKindRejected() {
        let raw = wrap("""
        {"kind":"hypothesis","summary":"考试","evidence":["准备考试"],"confidence":0.5}
        """)
        XCTAssertEqual(ReflectionInsightParser.parse(raw).failure, .invalidKind)
    }

    func testBooleanConfidenceRejected() {
        let raw = wrap("""
        {"kind":"recall_recent","summary":"考试","evidence":["准备考试"],"confidence":true}
        """)
        XCTAssertEqual(ReflectionInsightParser.parse(raw).failure, .invalidTypes)
    }

    func testEvidenceMustBeStringArray() {
        let raw = wrap("""
        {"kind":"recall_recent","summary":"考试","evidence":"准备考试","confidence":0.5}
        """)
        XCTAssertEqual(ReflectionInsightParser.parse(raw).failure, .invalidTypes)

        let mixed = wrap("""
        {"kind":"recall_recent","summary":"考试","evidence":["准备考试",1],"confidence":0.5}
        """)
        XCTAssertEqual(ReflectionInsightParser.parse(mixed).failure, .invalidTypes)
    }

    // MARK: - 边界值

    func testConfidenceClampedToUnitRange() {
        let raw = wrap("""
        {"kind":"recall_recent","summary":"考试","evidence":["准备考试"],"confidence":1.8},
        {"kind":"recall_recent","summary":"摄影课","evidence":["摄影课停了"],"confidence":-0.5}
        """)
        let result = ReflectionInsightParser.parse(raw)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.insights[0].confidence, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result.insights[1].confidence, 0.0, accuracy: 0.0001)
    }

    func testSummaryTruncatedToLimit() {
        let long = String(repeating: "a", count: 400)
        let raw = wrap("""
        {"kind":"recall_recent","summary":"\(long)","evidence":["准备考试"],"confidence":0.5}
        """)
        let result = ReflectionInsightParser.parse(raw)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.insights[0].summary.count, ReflectionInsightPolicy.maxSummaryLength)
    }

    // MARK: - 必须用户确认

    func testOnlyRecallDoesNotRequireConfirmation() {
        XCTAssertFalse(ReflectionInsightKind.recallRecent.requiresUserConfirmation)
        for kind in [ReflectionInsightKind.memoryLink, .worthRecording, .stanceChange, .correctionProposal] {
            XCTAssertTrue(kind.requiresUserConfirmation, "\(kind.rawValue) 必须经用户确认")
        }
    }

    // MARK: - 证据逐字校验

    func testEvidenceNotInContextIsFiltered() {
        let insight = ReflectionInsight(
            kind: .recallRecent,
            summary: "最近在准备考试",
            evidence: ["我最近在准备考试", "她昨天去了海边"],
            confidence: 0.8
        )
        let cleaned = ReflectionInsightPolicy.sanitize(insight, contextText: contextText)
        XCTAssertEqual(cleaned?.evidence, ["我最近在准备考试"])
    }

    func testInsightDroppedWhenAllEvidenceHallucinated() {
        let insight = ReflectionInsight(
            kind: .worthRecording,
            summary: "她昨天去了海边",
            evidence: ["她昨天去了海边"],
            confidence: 0.9
        )
        XCTAssertNil(ReflectionInsightPolicy.sanitize(insight, contextText: contextText))
    }

    func testInsightDroppedWhenSummaryEmpty() {
        let insight = ReflectionInsight(
            kind: .recallRecent,
            summary: "   ",
            evidence: ["准备考试"],
            confidence: 0.8
        )
        XCTAssertNil(ReflectionInsightPolicy.sanitize(insight, contextText: contextText))
    }

    func testInsightDroppedWhenConfidenceBelowFloor() {
        let insight = ReflectionInsight(
            kind: .recallRecent,
            summary: "考试",
            evidence: ["准备考试"],
            confidence: 0.1
        )
        XCTAssertNil(ReflectionInsightPolicy.sanitize(insight, contextText: contextText))
    }

    func testMemoryLinkWithoutTargetDropped() {
        let insight = ReflectionInsight(
            kind: .memoryLink,
            summary: "考试和摄影课",
            evidence: ["准备考试"],
            confidence: 0.8,
            targetMemoryID: nil
        )
        XCTAssertNil(ReflectionInsightPolicy.sanitize(insight, contextText: contextText))

        let withTarget = ReflectionInsight(
            kind: .memoryLink,
            summary: "考试和摄影课",
            evidence: ["准备考试"],
            confidence: 0.8,
            targetMemoryID: "mem1"
        )
        XCTAssertNotNil(ReflectionInsightPolicy.sanitize(withTarget, contextText: contextText))
    }

    func testEvidenceWhitespaceNormalizationAllowsLineBreaks() {
        let insight = ReflectionInsight(
            kind: .recallRecent,
            summary: "考试压力",
            evidence: ["我最近在准备考试，  压力有点大"],
            confidence: 0.8
        )
        XCTAssertNotNil(ReflectionInsightPolicy.sanitize(insight, contextText: contextText))
    }

    func testOverlongEvidenceDropped() {
        let long = String(repeating: "b", count: ReflectionInsightPolicy.maxEvidenceLength + 1)
        let insight = ReflectionInsight(
            kind: .recallRecent,
            summary: "考试",
            evidence: [long],
            confidence: 0.8
        )
        XCTAssertNil(ReflectionInsightPolicy.sanitize(insight, contextText: long))
    }

    // MARK: - 批量

    func testBatchDedupesByKindAndSummary() {
        let duplicated = ReflectionInsight(
            kind: .recallRecent,
            summary: "最近在准备考试",
            evidence: ["准备考试"],
            confidence: 0.8
        )
        let sameWithSpaces = ReflectionInsight(
            kind: .recallRecent,
            summary: "最近在准备考试 ",
            evidence: ["准备考试"],
            confidence: 0.7
        )
        let cleaned = ReflectionInsightPolicy.sanitizeBatch(
            [duplicated, sameWithSpaces],
            contextText: contextText
        )
        XCTAssertEqual(cleaned.count, 1)
    }

    func testBatchCapsAtMaxInsights() {
        let items = (0..<8).map { index in
            ReflectionInsight(
                kind: .recallRecent,
                summary: "第\(index)条回顾",
                evidence: ["准备考试"],
                confidence: 0.8
            )
        }
        let cleaned = ReflectionInsightPolicy.sanitizeBatch(items, contextText: contextText)
        XCTAssertEqual(cleaned.count, ReflectionInsightPolicy.maxInsights)
    }

    func testBatchDropsInvalidAndKeepsValidOrder() {
        let invalid = ReflectionInsight(
            kind: .worthRecording,
            summary: "编造的经历",
            evidence: ["昨天去了海边"],
            confidence: 0.9
        )
        let valid = ReflectionInsight(
            kind: .stanceChange,
            summary: "摄影课停了",
            evidence: ["摄影课停了"],
            confidence: 0.6
        )
        let cleaned = ReflectionInsightPolicy.sanitizeBatch([invalid, valid], contextText: contextText)
        XCTAssertEqual(cleaned.map(\.kind), [.stanceChange])
    }
}

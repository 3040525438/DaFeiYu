import XCTest
@testable import DFCore

/// D47：主动创建会话的决策策略（标题规范化、复用、去重、间隔、日上限、边界）。
final class NewConversationPolicyTests: XCTestCase {
    private let now: Int64 = 100 * 3_600_000

    private func candidate(
        title: String,
        anchor: String? = nil,
        key: String = "topic:test"
    ) -> NewConversationCandidate {
        NewConversationCandidate(titleDraft: title, topicAnchor: anchor, dedupeKey: key)
    }

    // MARK: - 标题规范化

    func testNormalizeFlattensWhitespaceAndTrimsPunctuation() {
        XCTAssertEqual(
            NewConversationPolicy.normalizeTitle("  今天\n的  面试！  "),
            "今天的 面试"
        )
        XCTAssertEqual(
            NewConversationPolicy.normalizeTitle("……好想去旅行？？？"),
            "好想去旅行"
        )
    }

    func testNormalizeRejectsTooShortOrPunctuationOnly() {
        XCTAssertEqual(NewConversationPolicy.normalizeTitle(""), "")
        XCTAssertEqual(NewConversationPolicy.normalizeTitle("  "), "")
        XCTAssertEqual(NewConversationPolicy.normalizeTitle("。"), "")
        XCTAssertEqual(NewConversationPolicy.normalizeTitle("好"), "", "少于 2 个字符视为没有话题")
        XCTAssertEqual(NewConversationPolicy.normalizeTitle("！！！"), "")
    }

    func testNormalizeTruncatesLongTitle() {
        let long = String(repeating: "长", count: 50)
        let result = NewConversationPolicy.normalizeTitle(long)
        XCTAssertEqual(result.count, NewConversationPolicy.maxTitleLength)
    }

    func testDeriveTitleFallsBackToAnchor() {
        let empty = candidate(title: "", anchor: "她说周五要去体检")
        XCTAssertEqual(NewConversationPolicy.deriveTitle(from: empty), "她说周五要去体检")

        let noTopic = candidate(title: "", anchor: nil)
        XCTAssertEqual(NewConversationPolicy.deriveTitle(from: noTopic), "")
    }

    // MARK: - 同主题判定

    func testTitlesOverlap() {
        XCTAssertTrue(NewConversationPolicy.titlesOverlap("面试准备", "面试准备"))
        XCTAssertTrue(NewConversationPolicy.titlesOverlap("面试", "下周的面试准备"))
        XCTAssertFalse(NewConversationPolicy.titlesOverlap("面试", "旅行"))
        XCTAssertFalse(NewConversationPolicy.titlesOverlap("", "旅行"))
    }

    // MARK: - 决策

    func testCreatesWhenNoConflict() {
        let decision = NewConversationPolicy.decide(
            candidate: candidate(title: "聊聊体检"),
            existing: [],
            lastCreatedAt: nil,
            createdToday: 0,
            nowMillis: now
        )
        XCTAssertEqual(decision, .create(title: "聊聊体检", reason: "出现了值得单独聊的新话题"))
    }

    func testReusesExistingSameTopicConversation() {
        let existing = [
            ExistingConversationBrief(id: "c1", title: "聊聊体检", createdAt: 0, isArchived: false)
        ]
        let decision = NewConversationPolicy.decide(
            candidate: candidate(title: "体检结果"),
            existing: existing,
            lastCreatedAt: nil,
            createdToday: 0,
            nowMillis: now
        )
        guard case .reuse(let id, let title, _) = decision else {
            return XCTFail("应复用已有会话，实际 \(decision)")
        }
        XCTAssertEqual(id, "c1")
        XCTAssertEqual(title, "聊聊体检")
    }

    func testArchivedConversationIsNotReused() {
        let existing = [
            ExistingConversationBrief(id: "c1", title: "聊聊体检", createdAt: 0, isArchived: true)
        ]
        let decision = NewConversationPolicy.decide(
            candidate: candidate(title: "聊聊体检"),
            existing: existing,
            lastCreatedAt: nil,
            createdToday: 0,
            nowMillis: now
        )
        guard case .create = decision else {
            return XCTFail("归档会话不应被复用，实际 \(decision)")
        }
    }

    func testSkipsWhenDedupeKeyUsed() {
        let decision = NewConversationPolicy.decide(
            candidate: candidate(title: "聊聊体检", key: "topic:体检"),
            existing: [],
            lastCreatedAt: nil,
            createdToday: 0,
            nowMillis: now,
            usedDedupeKeys: ["topic:体检"]
        )
        guard case .skip(let reason) = decision else {
            return XCTFail("应跳过，实际 \(decision)")
        }
        XCTAssertTrue(reason.contains("之前已经主动开过"))
    }

    func testSkipsWhenNoTopic() {
        let decision = NewConversationPolicy.decide(
            candidate: candidate(title: "。。", anchor: nil),
            existing: [],
            lastCreatedAt: nil,
            createdToday: 0,
            nowMillis: now
        )
        XCTAssertEqual(decision, .skip(reason: "没有足够明确的新话题"))
    }

    func testSkipsAtDailyLimit() {
        let decision = NewConversationPolicy.decide(
            candidate: candidate(title: "聊聊体检"),
            existing: [],
            lastCreatedAt: nil,
            createdToday: NewConversationPolicy.dailyLimit,
            nowMillis: now
        )
        guard case .skip(let reason) = decision else {
            return XCTFail("应跳过，实际 \(decision)")
        }
        XCTAssertTrue(reason.contains("达到上限"))
    }

    func testSkipsWithinMinInterval() {
        let last = now - 60 * 60_000  // 1 小时前
        let decision = NewConversationPolicy.decide(
            candidate: candidate(title: "聊聊体检"),
            existing: [],
            lastCreatedAt: last,
            createdToday: 1,
            nowMillis: now
        )
        guard case .skip(let reason) = decision else {
            return XCTFail("应跳过，实际 \(decision)")
        }
        XCTAssertTrue(reason.contains("还需"))
    }

    func testCreatesAfterMinInterval() {
        let last = now - Int64(NewConversationPolicy.minIntervalMinutes + 1) * 60_000
        let decision = NewConversationPolicy.decide(
            candidate: candidate(title: "聊聊体检"),
            existing: [],
            lastCreatedAt: last,
            createdToday: 1,
            nowMillis: now
        )
        guard case .create = decision else {
            return XCTFail("间隔已满足，应允许新建，实际 \(decision)")
        }
    }

    func testClockGoingBackwardsDoesNotBypassInterval() {
        let future = now + 3_600_000
        let decision = NewConversationPolicy.decide(
            candidate: candidate(title: "聊聊体检"),
            existing: [],
            lastCreatedAt: future,
            createdToday: 1,
            nowMillis: now
        )
        guard case .skip = decision else {
            return XCTFail("时钟回拨不应绕过最小间隔，实际 \(decision)")
        }
    }

    func testReuseTakesPriorityOverDailyLimit() {
        let existing = [
            ExistingConversationBrief(id: "c1", title: "聊聊体检", createdAt: 0, isArchived: false)
        ]
        let decision = NewConversationPolicy.decide(
            candidate: candidate(title: "体检"),
            existing: existing,
            lastCreatedAt: now,
            createdToday: NewConversationPolicy.dailyLimit,
            nowMillis: now
        )
        guard case .reuse = decision else {
            return XCTFail("复用不受日上限限制，实际 \(decision)")
        }
    }

    func testDecisionSummaryIsReadable() {
        XCTAssertTrue(
            NewConversationDecision.create(title: "聊聊体检", reason: "新话题")
                .summary.contains("新建会话")
        )
        XCTAssertTrue(
            NewConversationDecision.skip(reason: "没有话题").summary.contains("不新开会话")
        )
    }
}

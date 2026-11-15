import XCTest
@testable import DFCore

/// D37：情绪、异议、拒绝、幽默，以及真实 / 推断 / 想象三态的区分。
final class SelfExpressionTests: XCTestCase {
    // MARK: - 认识状态

    func testObservedAllowsFactualStatement() {
        XCTAssertTrue(EpistemicDisclosure.violations(stance: .observed, text: "我确实记得你上周说过想学吉他").isEmpty)
    }

    func testInferredWithFactMarkerIsViolation() {
        XCTAssertEqual(
            EpistemicDisclosure.violations(stance: .inferred, text: "我确定你喜欢下雨天"),
            [.inferredStatedAsFact]
        )
    }

    func testInferredWithHedgingIsClean() {
        XCTAssertTrue(EpistemicDisclosure.violations(stance: .inferred, text: "我猜你可能更喜欢安静一点的地方").isEmpty)
    }

    func testImaginedStatedAsFactIsViolation() {
        XCTAssertEqual(
            EpistemicDisclosure.violations(stance: .imagined, text: "我记得我们一起去过海边"),
            [.imaginedStatedAsFact]
        )
    }

    func testImaginedWithoutFramingIsViolation() {
        XCTAssertEqual(
            EpistemicDisclosure.violations(stance: .imagined, text: "我们在海边捡了很多贝壳"),
            [.unmarkedImagination]
        )
    }

    func testImaginedWithFramingIsClean() {
        XCTAssertTrue(
            EpistemicDisclosure.violations(stance: .imagined, text: "假设我们一起去海边，你会想捡贝壳吗").isEmpty
        )
    }

    func testEmptyTextIsRejected() {
        XCTAssertEqual(EpistemicDisclosure.violations(stance: .observed, text: "   "), [.emptyText])
    }

    func testUnknownStoredStatusFallsBackToInferred() {
        XCTAssertEqual(EpistemicStance(stored: "hallucinated"), .inferred)
        XCTAssertEqual(EpistemicStance(stored: " observed "), .observed)
        XCTAssertFalse(EpistemicStance.inferred.canAssertAsFact)
        XCTAssertFalse(EpistemicStance.imagined.canAssertAsFact)
        XCTAssertTrue(EpistemicStance.observed.canAssertAsFact)
    }

    func testContainsFactualAssertionHelper() {
        XCTAssertTrue(EpistemicDisclosure.containsFactualAssertion("事实上我早就知道"))
        XCTAssertFalse(EpistemicDisclosure.containsFactualAssertion("可能吧"))
    }

    // MARK: - 表达态度

    func testRefusalRequiresReason() {
        XCTAssertEqual(
            ExpressionPolicy.violations(stance: .refuse, text: "不行"),
            [.refusalWithoutReason]
        )
        XCTAssertTrue(
            ExpressionPolicy.violations(stance: .refuse, text: "现在不想聊这个，改天再说好吗").isEmpty
        )
    }

    func testDisagreementRequiresPoint() {
        XCTAssertEqual(
            ExpressionPolicy.violations(stance: .disagree, text: "你说得对"),
            [.disagreementWithoutPoint]
        )
        XCTAssertTrue(
            ExpressionPolicy.violations(stance: .disagree, text: "不过我觉得这件事还有另一个角度").isEmpty
        )
    }

    func testHumorMustNotBeHostile() {
        XCTAssertEqual(
            ExpressionPolicy.violations(stance: .humor, text: "你可真蠢"),
            [.humorWithHostility]
        )
        XCTAssertTrue(
            ExpressionPolicy.violations(stance: .humor, text: "行吧，今天算你赢，我请客").isEmpty
        )
    }

    func testEmotionalPressureIsRejectedInAnyStance() {
        XCTAssertEqual(
            ExpressionPolicy.violations(stance: .neutral, text: "你不回我我就一直难过"),
            [.emotionalPressure]
        )
        XCTAssertEqual(
            ExpressionPolicy.violations(stance: .refuse, text: "你必须陪我，不然我不理你"),
            [.refusalWithoutReason, .emotionalPressure]
        )
    }

    func testEmptyTextProducesNoExpressionViolation() {
        XCTAssertTrue(ExpressionPolicy.violations(stance: .refuse, text: " ").isEmpty)
    }

    // MARK: - 情绪

    func testEmotionIntensityIsClamped() {
        XCTAssertEqual(EmotionState(kind: .joyful, intensity: 1.5).intensity, 1)
        XCTAssertEqual(EmotionState(kind: .joyful, intensity: -0.4).intensity, 0)
        XCTAssertEqual(EmotionState(kind: .joyful, intensity: .nan).intensity, 0)
    }

    func testEmotionTierBoundaries() {
        XCTAssertEqual(EmotionState(kind: .sad, intensity: 0.33).tier, .low)
        XCTAssertEqual(EmotionState(kind: .sad, intensity: 0.34).tier, .mid)
        XCTAssertEqual(EmotionState(kind: .sad, intensity: 0.66).tier, .mid)
        XCTAssertEqual(EmotionState(kind: .sad, intensity: 0.67).tier, .high)
    }

    func testEmotionDirectiveKeepsFactsUntouched() {
        let state = EmotionState(kind: .annoyed, intensity: 0.9, reason: "被打断太多次")
        let text = EmotionGuidance.directive(state)
        XCTAssertTrue(text.contains("有点烦"))
        XCTAssertTrue(text.contains("被打断太多次"))
        XCTAssertTrue(text.contains("不改变事实陈述"))
        XCTAssertTrue(text.contains("禁止讽刺"))
    }

    func testSystemFragmentWithoutEmotionMatchesBase() {
        XCTAssertEqual(SelfExpressionProtocol.promptFragment(emotion: nil), SelfExpressionProtocol.systemFragment)
        let withEmotion = SelfExpressionProtocol.promptFragment(
            emotion: EmotionState(kind: .warm, intensity: 0.6)
        )
        XCTAssertTrue(withEmotion.hasPrefix(SelfExpressionProtocol.systemFragment))
        XCTAssertTrue(withEmotion.contains("当前情绪：温和"))
    }

    // MARK: - 统一审计

    func testAuditCombinesEpistemicAndExpressionViolations() {
        let audit = SelfExpression.audit(
            text: "我确定我们一起去过海边，不过这不重要",
            stance: .imagined,
            expression: .disagree
        )
        XCTAssertFalse(audit.isClean)
        XCTAssertTrue(audit.epistemicViolations.contains(.imaginedStatedAsFact))
        XCTAssertTrue(audit.messages.count >= 1)

        let clean = SelfExpression.audit(
            text: "不过我觉得今天风挺舒服的",
            stance: .inferred,
            expression: .disagree
        )
        XCTAssertTrue(clean.isClean)
    }
}

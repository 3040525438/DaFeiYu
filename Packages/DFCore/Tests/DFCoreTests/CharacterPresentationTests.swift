import XCTest
@testable import DFCore

/// D36：表情/动作映射与互动动画的纯逻辑约束。
final class CharacterPresentationTests: XCTestCase {
    // MARK: - 表情码

    func testUnknownStoredMoodFallsBackToNeutral() {
        XCTAssertEqual(CharacterMood(stored: "dancing"), .neutral)
        XCTAssertEqual(CharacterMood(stored: "  joyful  "), .joyful)
    }

    func testEmotionMapsToMoodOneToOne() {
        XCTAssertEqual(CharacterMood(emotion: .calm), .calm)
        XCTAssertEqual(CharacterMood(emotion: .warm), .warm)
        XCTAssertEqual(CharacterMood(emotion: .joyful), .joyful)
        XCTAssertEqual(CharacterMood(emotion: .sad), .sad)
        XCTAssertEqual(CharacterMood(emotion: .anxious), .anxious)
        XCTAssertEqual(CharacterMood(emotion: .annoyed), .annoyed)
        XCTAssertEqual(CharacterMood(emotion: .excited), .excited)
    }

    func testArousalClassification() {
        XCTAssertTrue(CharacterMood.sleepy.isLowArousal)
        XCTAssertTrue(CharacterMood.sad.isLowArousal)
        XCTAssertTrue(CharacterMood.calm.isLowArousal)
        XCTAssertFalse(CharacterMood.joyful.isLowArousal)
        XCTAssertTrue(CharacterMood.joyful.isHighArousal)
        XCTAssertTrue(CharacterMood.excited.isHighArousal)
        XCTAssertFalse(CharacterMood.neutral.isHighArousal)
    }

    // MARK: - 数值夹取

    func testClampHandlesOutOfRangeAndNaN() {
        XCTAssertEqual(CharacterPresentationPolicy.clamp(1.8), 1)
        XCTAssertEqual(CharacterPresentationPolicy.clamp(-0.4), 0)
        XCTAssertEqual(CharacterPresentationPolicy.clamp(.nan), 0.5)
    }

    func testAnimationClampsItsOwnFields() {
        let animation = CharacterAnimation(duration: -2, repeatCount: -3, scale: 9, intensity: 4)
        XCTAssertEqual(animation.duration, 0)
        XCTAssertEqual(animation.repeatCount, 0)
        XCTAssertEqual(animation.scale, 1.5)
        XCTAssertEqual(animation.intensity, 1)
        XCTAssertFalse(animation.isAnimated)
    }

    func testAnimationNaNScaleAndIntensityAreSafe() {
        let animation = CharacterAnimation(duration: 1, repeatCount: 1, scale: .nan, intensity: .nan)
        XCTAssertEqual(animation.scale, 1)
        XCTAssertEqual(animation.intensity, 0)
    }

    // MARK: - 动作选择

    func testExhaustedEnergyForcesRest() {
        let presentation = CharacterPresentationPolicy.make(mood: .excited, energy: 0.1, affinity: 0.9)
        XCTAssertEqual(presentation.action, .rest)
        XCTAssertLessThan(presentation.animation.intensity, 0.15)
    }

    func testHighArousalWavesWhenEnergyIsEnough() {
        XCTAssertEqual(
            CharacterPresentationPolicy.make(mood: .joyful, energy: 0.8, affinity: 0.8).action,
            .wave
        )
        XCTAssertEqual(
            CharacterPresentationPolicy.make(mood: .excited, energy: 0.6, affinity: 0.5).action,
            .wave
        )
    }

    func testAnxiousThinks() {
        XCTAssertEqual(
            CharacterPresentationPolicy.make(mood: .anxious, energy: 0.6, affinity: 0.6).action,
            .think
        )
    }

    func testLowArousalStaysIdle() {
        XCTAssertEqual(
            CharacterPresentationPolicy.make(mood: .sad, energy: 0.7, affinity: 0.7).action,
            .idle
        )
        XCTAssertEqual(
            CharacterPresentationPolicy.make(mood: .sleepy, energy: 0.5, affinity: 0.5).action,
            .idle
        )
    }

    func testNeutralNods() {
        XCTAssertEqual(
            CharacterPresentationPolicy.make(mood: .neutral, energy: 0.6, affinity: 0.6).action,
            .nod
        )
    }

    // MARK: - 幅度

    func testDistantAffinityHalvesIntensity() {
        let close = CharacterPresentationPolicy.make(mood: .neutral, energy: 0.8, affinity: 0.9)
        let distant = CharacterPresentationPolicy.make(mood: .neutral, energy: 0.8, affinity: 0.1)
        XCTAssertEqual(distant.animation.intensity, close.animation.intensity * 0.5, accuracy: 0.0001)
    }

    func testVeryLowIntensityDoesNotRepeat() {
        let presentation = CharacterPresentationPolicy.make(mood: .neutral, energy: 0.3, affinity: 0.1)
        XCTAssertEqual(presentation.animation.repeatCount, 1)
    }

    func testSameInputIsDeterministic() {
        let first = CharacterPresentationPolicy.make(mood: .warm, energy: 0.42, affinity: 0.66)
        let second = CharacterPresentationPolicy.make(mood: .warm, energy: 0.42, affinity: 0.66)
        XCTAssertEqual(first, second)
    }

    // MARK: - 减弱动态效果

    func testReduceMotionProducesStillAnimation() {
        let presentation = CharacterPresentationPolicy.make(
            mood: .excited,
            energy: 1,
            affinity: 1,
            reduceMotion: true
        )
        XCTAssertFalse(presentation.animation.isAnimated)
        XCTAssertEqual(presentation.animation.scale, 1)
        // 表情与动作仍保留，只是不动
        XCTAssertEqual(presentation.mood, .excited)
        XCTAssertEqual(presentation.action, .wave)
    }

    func testMoodCodeFactoryMatchesDirectCall() {
        XCTAssertEqual(
            CharacterPresentationPolicy.make(moodCode: "unknown", energy: 0.5, affinity: 0.5),
            CharacterPresentationPolicy.make(mood: .neutral, energy: 0.5, affinity: 0.5)
        )
    }

    // MARK: - 互动动画

    func testEveryPhaseHasDistinctAnimation() {
        let animations = ChatTurnPhase.allCases.map { InteractionAnimationPolicy.animation(for: $0) }
        XCTAssertEqual(animations.count, ChatTurnPhase.allCases.count)
        XCTAssertEqual(Set(animations.map(\.rawValue)).count, animations.count, "每个状态应有独立动画")
    }

    func testOnlyOngoingAndIdlePhasesLoop() {
        XCTAssertTrue(InteractionAnimationPolicy.animation(for: .idle).loops, "待机呼吸应循环")
        XCTAssertTrue(InteractionAnimationPolicy.animation(for: .generating).loops)
        XCTAssertTrue(InteractionAnimationPolicy.animation(for: .thinking).loops)
        XCTAssertTrue(InteractionAnimationPolicy.animation(for: .paused).loops)
        XCTAssertFalse(InteractionAnimationPolicy.animation(for: .completed).loops)
        XCTAssertFalse(InteractionAnimationPolicy.animation(for: .failed).loops)
        XCTAssertFalse(InteractionAnimationPolicy.animation(for: .stopped).loops)
    }

    func testTerminalAnimationsAreShort() {
        for animation in [InteractionAnimation.settle, .shake, .fading] {
            XCTAssertLessThanOrEqual(InteractionAnimationPolicy.duration(for: animation), 0.5)
        }
    }
}

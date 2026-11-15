import XCTest
@testable import DFCore

/// 紧迫度 / 节奏信号与 `AutonomyGate` 的联动：只收紧、不放宽，且默认不改变既有行为。
final class AutonomyGateRhythmTests: XCTestCase {
    private let noon = 12 * 60

    private func evaluate(
        urgency: Double?,
        speakReason: ReflectionSpeakReason = .silenceConcern,
        cadence: CadenceSignals? = nil,
        trigger: ProactiveTrigger = .message
    ) -> AutonomyDecision {
        AutonomyGate.evaluate(
            policy: .default,
            trigger: trigger,
            nowMillis: 1_000_000,
            nowMinuteOfDay: noon,
            lastSentAt: nil,
            todaySentCount: 0,
            urgency: urgency,
            speakReason: speakReason,
            cadence: cadence
        )
    }

    func testNoUrgencyKeepsLegacyBehavior() {
        XCTAssertTrue(evaluate(urgency: nil).allowed)
    }

    func testLowUrgencyBlocks() {
        let decision = evaluate(urgency: 0.1)
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.reason, "反思紧迫度不足，暂不打扰")
    }

    func testHighUrgencyAllows() {
        XCTAssertTrue(evaluate(urgency: 0.9).allowed)
    }

    func testUrgencyAtThresholdBoundary() {
        // 恰好等于阈值视为放行（>= 语义）
        XCTAssertTrue(
            evaluate(urgency: ReflectionCadence.balancedThreshold).allowed
        )
    }

    func testNoneReasonBlocksEvenWithHighUrgency() {
        XCTAssertFalse(evaluate(urgency: 1.0, speakReason: .none).allowed)
    }

    func testQuickCadenceBlocksRegardlessOfUrgency() {
        let quick = CadenceSignals(
            recentCount: 9,
            averageGapMinutes: 0.8,
            lastGapMinutes: 0.1,
            isQuick: true,
            isSlow: false
        )
        let decision = evaluate(urgency: 0.95, cadence: quick)
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.reason, "用户正在连续互动，暂不主动打扰")
    }

    func testRhythmDoesNotAffectNonIntrusiveTriggers() {
        // 记忆整理不打扰用户，节奏信号不参与
        XCTAssertTrue(
            evaluate(urgency: 0.01, trigger: .memoryConsolidation).allowed
        )
        XCTAssertTrue(
            evaluate(urgency: 0.01, trigger: .selfReflection).allowed
        )
    }

    func testRhythmCannotBypassQuietHours() {
        let decision = AutonomyGate.evaluate(
            policy: .default,
            trigger: .message,
            nowMillis: 1_000_000,
            nowMinuteOfDay: 23 * 60 + 30,
            lastSentAt: nil,
            todaySentCount: 0,
            urgency: 1.0,
            speakReason: .emotionalOverflow,
            cadence: .idle
        )
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.reason, "当前处于免打扰时段")
    }
}

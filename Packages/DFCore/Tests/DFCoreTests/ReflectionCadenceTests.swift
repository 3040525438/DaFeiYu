import XCTest
@testable import DFCore

/// W7-Shikigami：反思输出的严格 Schema 校验、紧迫度夹取、自适应间隔、重启续算与节奏信号。
final class ReflectionCadenceTests: XCTestCase {

    // MARK: - 严格 Schema

    func testStrictParseAcceptsFullSchema() throws {
        let raw = """
        {"thought":"想问问她今天面试怎么样","style_hint":"温柔一点","urgency":0.72,
         "topic_pick":"工作","topic_anchor":"面试","next_reflection_in":600,
         "speak_reason":"memory_recall"}
        """
        let result = ReflectionOutputParser.parse(raw)
        XCTAssertNil(result.failure)
        XCTAssertTrue(result.isStrict)
        XCTAssertEqual(result.state.thought, "想问问她今天面试怎么样")
        XCTAssertEqual(result.state.styleHint, "温柔一点")
        XCTAssertEqual(result.state.urgency, 0.72, accuracy: 0.0001)
        XCTAssertEqual(result.state.topicPick, "工作")
        XCTAssertEqual(result.state.topicAnchor, "面试")
        XCTAssertEqual(result.state.nextReflectionIn, 600)
        XCTAssertEqual(result.state.speakReason, .memoryRecall)
        XCTAssertTrue(result.state.wantsToSpeak)
    }

    func testParseAcceptsCodeFenceButKeepsStrictSchema() {
        let raw = """
        ```json
        {"thought":"安静一会儿","urgency":0.1,"next_reflection_in":1200,"speak_reason":"none"}
        ```
        """
        let result = ReflectionOutputParser.parse(raw)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.state.speakReason, .none)
        XCTAssertFalse(result.state.wantsToSpeak)
    }

    func testOptionalKeysMayBeNullButMustExistWhenRequired() {
        let raw = """
        {"thought":"随便想想","style_hint":null,"urgency":0.2,"topic_pick":null,
         "topic_anchor":null,"next_reflection_in":null,"speak_reason":"none"}
        """
        let result = ReflectionOutputParser.parse(raw)
        XCTAssertNil(result.failure)
        XCTAssertNil(result.state.styleHint)
        XCTAssertNil(result.state.topicPick)
        XCTAssertNil(result.state.topicAnchor)
        XCTAssertEqual(
            result.state.nextReflectionIn,
            ReflectionCadence.defaultIntervalSeconds,
            "显式 null 的间隔应回退默认值"
        )
    }

    // MARK: - 异常输入 / 解析失败

    func testEmptyOutputFallsBackToDefault() {
        let result = ReflectionOutputParser.parse("   \n ")
        XCTAssertEqual(result.failure, .emptyOutput)
        XCTAssertEqual(result.state, .default)
    }

    func testNonJSONOutputFallsBackToDefault() {
        XCTAssertEqual(
            ReflectionOutputParser.parse("我想说点什么").failure,
            .notJSONObject
        )
        XCTAssertEqual(
            ReflectionOutputParser.parse("[1,2,3]").failure,
            .notJSONObject
        )
    }

    func testUnknownKeyIsRejected() {
        let raw = """
        {"thought":"x","urgency":0.5,"next_reflection_in":600,"speak_reason":"none","extra":1}
        """
        let result = ReflectionOutputParser.parse(raw)
        XCTAssertEqual(result.failure, .unknownKeys)
        XCTAssertEqual(result.state, .default, "降级后不得保留半成品字段")
    }

    func testMissingRequiredKeyIsRejected() {
        let raw = """
        {"thought":"x","next_reflection_in":600,"speak_reason":"none"}
        """
        XCTAssertEqual(ReflectionOutputParser.parse(raw).failure, .missingKeys)
    }

    func testWrongTypesAreRejected() {
        // urgency 为字符串
        XCTAssertEqual(
            ReflectionOutputParser.parse(
                #"{"thought":"x","urgency":"0.8","next_reflection_in":600,"speak_reason":"none"}"#
            ).failure,
            .invalidTypes
        )
        // thought 为数字
        XCTAssertEqual(
            ReflectionOutputParser.parse(
                #"{"thought":1,"urgency":0.8,"next_reflection_in":600,"speak_reason":"none"}"#
            ).failure,
            .invalidTypes
        )
    }

    func testUnknownSpeakReasonIsRejected() {
        let raw = """
        {"thought":"x","urgency":0.9,"next_reflection_in":600,"speak_reason":"just_chat"}
        """
        XCTAssertEqual(ReflectionOutputParser.parse(raw).failure, .invalidSpeakReason)
    }

    // MARK: - 边界值

    func testUrgencyIsClampedToUnitRange() {
        let over = ReflectionOutputParser.parse(
            #"{"thought":"x","urgency":9.5,"next_reflection_in":600,"speak_reason":"none"}"#
        )
        XCTAssertEqual(over.state.urgency, 1.0, accuracy: 0.0001)

        let under = ReflectionOutputParser.parse(
            #"{"thought":"x","urgency":-3,"next_reflection_in":600,"speak_reason":"none"}"#
        )
        XCTAssertEqual(under.state.urgency, 0.0, accuracy: 0.0001)
        XCTAssertNil(under.failure, "越界值应被夹取，而不是判 Schema 失败")
    }

    func testIntervalBoundaries() {
        XCTAssertEqual(ReflectionCadence.clampInterval(0), ReflectionCadence.defaultIntervalSeconds)
        XCTAssertEqual(ReflectionCadence.clampInterval(-5), ReflectionCadence.defaultIntervalSeconds)
        XCTAssertEqual(ReflectionCadence.clampInterval(1), ReflectionCadence.minIntervalSeconds)
        XCTAssertEqual(ReflectionCadence.clampInterval(99_999), ReflectionCadence.maxIntervalSeconds)
        XCTAssertEqual(ReflectionCadence.clampInterval(600), 600)
    }

    func testUrgencyClampHandlesNonFinite() {
        XCTAssertEqual(ReflectionCadence.clampUrgency(.nan), 0)
        XCTAssertEqual(ReflectionCadence.clampUrgency(.infinity), 0)
        XCTAssertEqual(ReflectionCadence.clampUrgency(-.infinity), 0)
    }

    // MARK: - 说话阈值

    func testShouldSpeakRequiresReasonAndThreshold() {
        XCTAssertFalse(
            ReflectionCadence.shouldSpeak(urgency: 0.99, speakReason: .none),
            "理由为 none 时再高的紧迫度也不能说话"
        )
        XCTAssertFalse(
            ReflectionCadence.shouldSpeak(urgency: 0.1, speakReason: .silenceConcern)
        )
        XCTAssertTrue(
            ReflectionCadence.shouldSpeak(urgency: 0.4, speakReason: .silenceConcern)
        )
        XCTAssertTrue(
            ReflectionCadence.shouldSpeak(
                urgency: 0.25,
                speakReason: .trendShare,
                threshold: ReflectionCadence.eagerThreshold
            )
        )
        XCTAssertFalse(
            ReflectionCadence.shouldSpeak(
                urgency: 0.5,
                speakReason: .trendShare,
                threshold: ReflectionCadence.conservativeThreshold
            )
        )
    }

    // MARK: - 重启续算

    func testResumeDelayWhenNeverReflected() {
        XCTAssertEqual(
            ReflectionCadence.resumeDelayMillis(
                lastUpdatedAt: nil,
                intervalSeconds: 900,
                nowMillis: 10_000
            ),
            0
        )
    }

    func testResumeDelayComputesRemainingTime() {
        // 上次 0 时刻，间隔 600 秒，现在过了 100 秒 → 还差 500 秒
        XCTAssertEqual(
            ReflectionCadence.resumeDelayMillis(
                lastUpdatedAt: 0,
                intervalSeconds: 600,
                nowMillis: 100_000
            ),
            500_000
        )
    }

    func testResumeDelayNeverNegative() {
        XCTAssertEqual(
            ReflectionCadence.resumeDelayMillis(
                lastUpdatedAt: 0,
                intervalSeconds: 600,
                nowMillis: 9_999_999
            ),
            0
        )
    }

    func testResumeDelayClampsBadInterval() {
        // 非法间隔回退默认值 900 秒
        XCTAssertEqual(
            ReflectionCadence.resumeDelayMillis(
                lastUpdatedAt: 0,
                intervalSeconds: -1,
                nowMillis: 0
            ),
            900_000
        )
    }

    // MARK: - 节奏信号

    func testCadenceDetectsQuickInteraction() {
        let now: Int64 = 10 * 60_000
        // 每 1 分钟一条，共 8 条
        let timestamps = (0..<8).map { now - Int64($0) * 60_000 }
        let signals = CadenceSignals.compute(timestamps: timestamps, nowMillis: now)
        XCTAssertEqual(signals.recentCount, 8)
        XCTAssertTrue(signals.isQuick)
        XCTAssertFalse(signals.isSlow)
        XCTAssertEqual(signals.lastGapMinutes ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(signals.averageGapMinutes ?? -1, 1, accuracy: 0.0001)
    }

    func testCadenceDetectsSilence() {
        let now: Int64 = 10 * 3_600_000
        let signals = CadenceSignals.compute(
            timestamps: [now - 4 * 3_600_000],
            nowMillis: now
        )
        XCTAssertEqual(signals.recentCount, 0, "窗口外样本不计入")
        XCTAssertTrue(signals.isSlow)
        XCTAssertFalse(signals.isQuick)
    }

    func testCadenceIgnoresFutureTimestampsAndKeepsOrder() {
        let now: Int64 = 3_600_000
        let signals = CadenceSignals.compute(
            timestamps: [now + 60_000, now - 30 * 60_000, now - 10 * 60_000],
            nowMillis: now
        )
        XCTAssertEqual(signals.recentCount, 2)
        XCTAssertEqual(signals.lastGapMinutes ?? -1, 10, accuracy: 0.0001)
    }

    func testCadenceWithEmptyInput() {
        XCTAssertEqual(CadenceSignals.compute(timestamps: [], nowMillis: 1), .idle)
        XCTAssertNil(CadenceSignals.compute(timestamps: [], nowMillis: 1).lastGapMinutes)
    }

    // MARK: - 与闸门联动

    func testRhythmBlocksWhenUserIsTypingQuickly() {
        let quick = CadenceSignals(
            recentCount: 8, averageGapMinutes: 1, lastGapMinutes: 0.5,
            isQuick: true, isSlow: false
        )
        let reason = ReflectionRhythm.blockReason(
            signals: quick,
            urgency: 0.9,
            speakReason: .silenceConcern
        )
        XCTAssertEqual(reason, "用户正在连续互动，暂不主动打扰")
    }

    func testRhythmBlocksLowUrgency() {
        let idle = CadenceSignals(
            recentCount: 0, averageGapMinutes: nil, lastGapMinutes: 400,
            isQuick: false, isSlow: true
        )
        XCTAssertEqual(
            ReflectionRhythm.blockReason(
                signals: idle,
                urgency: 0.1,
                speakReason: .trendShare
            ),
            "反思紧迫度不足，暂不打扰"
        )
        XCTAssertNil(
            ReflectionRhythm.blockReason(
                signals: idle,
                urgency: 0.8,
                speakReason: .trendShare
            )
        )
    }

    func testRhythmPassesWhenNothingToSayButReasonIsNone() {
        XCTAssertEqual(
            ReflectionRhythm.blockReason(
                signals: nil,
                urgency: 0,
                speakReason: .none
            ),
            "反思紧迫度不足，暂不打扰"
        )
    }
}

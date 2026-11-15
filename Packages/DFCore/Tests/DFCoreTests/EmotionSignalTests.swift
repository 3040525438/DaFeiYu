import XCTest
@testable import DFCore

/// D37 情绪数据源：纯规则推断、优先级、衰减与确定性。
final class EmotionSignalTests: XCTestCase {

    func testDistressMapsToWarmCare() {
        let state = EmotionSignal.infer(userText: "今天好累，感觉撑不住了")
        XCTAssertEqual(state.kind, .warm)
        XCTAssertEqual(state.intensity, 0.7)
        XCTAssertEqual(state.reason, "用户在表达难受或疲惫")
    }

    func testAffectionMapsToWarm() {
        let state = EmotionSignal.infer(userText: "谢谢你陪我")
        XCTAssertEqual(state.kind, .warm)
        XCTAssertEqual(state.reason, "用户在表达亲近")
    }

    func testJoyMapsToJoyful() {
        let state = EmotionSignal.infer(userText: "太好了，方案搞定了")
        XCTAssertEqual(state.kind, .joyful)
        XCTAssertEqual(state.reason, "用户心情不错")
    }

    func testUrgencyMapsToAnxious() {
        let state = EmotionSignal.infer(userText: "快点，等很久了")
        XCTAssertEqual(state.kind, .anxious)
        XCTAssertEqual(state.reason, "用户语气比较急")
    }

    func testDistressWinsOverJoyAndAffection() {
        // "虽然难过但还是谢谢你"：先照顾难受
        let state = EmotionSignal.infer(userText: "虽然很难过，但还是谢谢你")
        XCTAssertEqual(state.kind, .warm)
        XCTAssertEqual(state.reason, "用户在表达难受或疲惫")
    }

    func testNoSignalWithoutPreviousFallsBackToCalm() {
        let state = EmotionSignal.infer(userText: "把这段代码改成异步的")
        XCTAssertEqual(state.kind, .calm)
        XCTAssertEqual(state.reason, "这一轮没有明显的情绪线索")
    }

    func testNoSignalDecaysPreviousEmotion() {
        let previous = EmotionState(kind: .joyful, intensity: 0.65)
        let state = EmotionSignal.infer(userText: "继续", previous: previous)
        XCTAssertEqual(state.kind, .joyful)
        XCTAssertEqual(state.intensity, 0.45, accuracy: 0.0001)
        XCTAssertEqual(state.reason, "情绪自然回落")
    }

    func testDecayReachesCalmBelowWatermark() {
        let previous = EmotionState(kind: .anxious, intensity: 0.2)
        let state = EmotionSignal.infer(userText: "继续", previous: previous)
        XCTAssertEqual(state.kind, .calm)
        XCTAssertEqual(state.reason, "情绪已平复")
    }

    func testCalmPreviousStaysCalm() {
        let previous = EmotionState(kind: .calm, intensity: 0.9)
        let state = EmotionSignal.infer(userText: "继续", previous: previous)
        XCTAssertEqual(state.kind, .calm)
        XCTAssertEqual(state.reason, "这一轮没有明显的情绪线索")
    }

    func testInferIsDeterministic() {
        let a = EmotionSignal.infer(userText: "好开心哈哈")
        let b = EmotionSignal.infer(userText: "好开心哈哈")
        XCTAssertEqual(a, b)
    }

    func testEnglishCaseInsensitiveButChineseUnaffected() {
        XCTAssertEqual(EmotionSignal.infer(userText: "OK 太好了").kind, .joyful)
    }

    func testMoodToEmotionMapping() {
        XCTAssertEqual(EmotionKind(mood: .sleepy), .calm)
        XCTAssertEqual(EmotionKind(mood: .neutral), .calm)
        XCTAssertEqual(EmotionKind(mood: .sad), .sad)
        XCTAssertEqual(EmotionKind(mood: .excited), .excited)
        XCTAssertEqual(EmotionKind(mood: .annoyed), .annoyed)
    }
}

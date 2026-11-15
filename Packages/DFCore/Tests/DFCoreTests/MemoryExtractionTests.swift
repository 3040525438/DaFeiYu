import XCTest
@testable import DFCore

/// W8-3：记忆抽取提示词与解析（模型输出 → 候选 → 筛查）
final class MemoryExtractionTests: XCTestCase {
    private let sourceText = "用户：我最近喜欢上了桂花味的一切，还买了一瓶香水\n助手：桂花确实很温柔。"

    func testParseExtractsCandidateWithDedupeKey() {
        let raw = """
        [
          {
            "subject": "user",
            "layer": "semantic",
            "category": "preference",
            "title": "喜欢桂花",
            "content": "用户喜欢桂花味的一切",
            "evidence": "喜欢上了桂花味",
            "importance": 0.6,
            "confidence": 0.8
          }
        ]
        """
        let result = MemoryExtractionParser.parse(raw, sourceText: sourceText)
        XCTAssertEqual(result.accepted.count, 1)
        let candidate = result.accepted[0]
        XCTAssertEqual(candidate.scope, .user)
        XCTAssertEqual(candidate.layer, .semantic)
        XCTAssertEqual(candidate.category, "preference")
        XCTAssertFalse(candidate.scopeNeedsConfirmation)
        XCTAssertNotNil(candidate.dedupeKey)
        XCTAssertTrue(candidate.dedupeKey?.hasPrefix("user|semantic|preference|") == true)
    }

    func testParseStripsCodeFence() {
        let raw = """
        好的，结果如下：
        ```json
        [{"subject":"self","layer":"reflective","category":"emotion_pattern","title":"在意陪伴","content":"助理在意被记住","evidence":"桂花确实很温柔","importance":0.4}]
        ```
        以上。
        """
        let result = MemoryExtractionParser.parse(raw, sourceText: sourceText)
        XCTAssertEqual(result.accepted.count, 1)
        XCTAssertEqual(result.accepted[0].scope, .selfScope)
    }

    func testParseDropsFabricatedEvidence() {
        let raw = """
        [{"subject":"user","layer":"semantic","category":"fact","title":"养猫","content":"用户养了两只猫","evidence":"我养了两只猫","importance":0.5}]
        """
        let result = MemoryExtractionParser.parse(raw, sourceText: sourceText)
        XCTAssertTrue(result.accepted.isEmpty, "原文找不到的证据必须整条丢弃")
        XCTAssertEqual(result.rejections.count, 1)
        XCTAssertEqual(result.rejections[0].reason, .evidenceNotLocated)
    }

    func testParseUnknownSubjectRequiresConfirmation() {
        let raw = """
        [{"subject":"unknown","layer":"semantic","category":"fact","title":"香水","content":"买了一瓶香水","evidence":"还买了一瓶香水","importance":0.3}]
        """
        let result = MemoryExtractionParser.parse(raw, sourceText: sourceText)
        XCTAssertEqual(result.accepted.count, 1)
        XCTAssertTrue(result.accepted[0].scopeNeedsConfirmation, "主语不明不得静默归类")
        XCTAssertEqual(MemoryExtractionPolicy.default.route(for: result.accepted[0]), .confirm)
    }

    func testParseEmptyArrayYieldsNothing() {
        let result = MemoryExtractionParser.parse("[]", sourceText: sourceText)
        XCTAssertTrue(result.accepted.isEmpty)
        XCTAssertTrue(result.rejections.isEmpty)
    }

    func testParseInvalidJSONYieldsNothing() {
        let result = MemoryExtractionParser.parse("抱歉，我无法完成。", sourceText: sourceText)
        XCTAssertTrue(result.accepted.isEmpty)
    }

    func testParseCapsCandidatesPerTurn() {
        let items = (0..<12).map { index in
            """
            {"subject":"user","layer":"semantic","category":"fact","title":"要点\(index)","content":"第 \(index) 条对桂花味的补充说明","evidence":"喜欢上了桂花味","importance":0.2}
            """
        }
        let raw = "[" + items.joined(separator: ",") + "]"
        let result = MemoryExtractionParser.parse(raw, sourceText: sourceText)
        XCTAssertLessThanOrEqual(result.accepted.count, MemoryExtractionPolicy.default.maxCandidatesPerTurn)
    }

    func testPromptStatesEvidenceRuleAndNoSpeculation() {
        XCTAssertTrue(MemoryExtractionPrompt.system.contains("逐字"))
        XCTAssertTrue(MemoryExtractionPrompt.system.contains("不推断"))
        let message = MemoryExtractionPrompt.userMessage(
            for: MemoryExtractionInput(userText: "你好", assistantText: "在的", knownFacts: ["用户喜欢桂花"])
        )
        XCTAssertTrue(message.contains("已知事实"))
        XCTAssertTrue(message.contains("用户说"))
    }
}

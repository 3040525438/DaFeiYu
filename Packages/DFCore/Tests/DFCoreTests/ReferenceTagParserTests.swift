import XCTest
@testable import DFCore

/// A1 · R 系列（解析部分）：流式尾注解析与正文保护
final class ReferenceTagParserTests: XCTestCase {

    // MARK: - R01 无尾注

    func testR01_NoTag_ReturnsRawText() {
        var parser = StreamingReferenceParser()
        XCTAssertEqual(parser.feed("今天天气不错"), "今天天气不错")
        let output = parser.finish()
        XCTAssertEqual(output.visibleText, "今天天气不错")
        XCTAssertEqual(output.citations, [])
        XCTAssertFalse(output.parseFailed)
    }

    // MARK: - R02 正常尾注（末尾单独一行）

    func testR02_TrailingTagIsStripped() {
        var parser = StreamingReferenceParser()
        _ = parser.feed("我记得你说过\n")
        _ = parser.feed("<<refs:[\"m1\"]>>")
        let output = parser.finish()

        XCTAssertEqual(output.visibleText, "我记得你说过\n", "尾注之外逐字符保留")
        XCTAssertEqual(output.citations, ["m1"])
        XCTAssertFalse(output.parseFailed)
    }

    // MARK: - R03 尾注跨多个 delta

    func testR03_TagSplitAcrossDeltas() {
        var parser = StreamingReferenceParser()
        XCTAssertEqual(parser.feed("你好\n"), "你好\n")
        XCTAssertEqual(parser.feed("<<ref"), "", "疑似前缀应被扣留")
        XCTAssertEqual(parser.feed("s:[\"m1\",\"m2\"]>>"), "")
        let output = parser.finish()

        XCTAssertEqual(output.visibleText, "你好\n")
        XCTAssertEqual(output.citations, ["m1", "m2"])
    }

    // MARK: - R04 缺少 >>

    func testR04_MissingClosingBrackets_KeepsRaw() {
        var parser = StreamingReferenceParser()
        _ = parser.feed("正文\n<<refs:[\"m1\"]")
        let output = parser.finish()

        XCTAssertEqual(output.visibleText, "正文\n<<refs:[\"m1\"]")
        XCTAssertEqual(output.citations, [])
    }

    // MARK: - R05 正文中间出现标记

    func testR05_TagInMiddleIsPlainText() {
        let raw = "看 <<refs:abc 然后继续聊别的"
        var parser = StreamingReferenceParser()
        _ = parser.feed(raw)
        let output = parser.finish()

        XCTAssertEqual(output.visibleText, raw)
        XCTAssertEqual(output.citations, [])
        XCTAssertFalse(output.parseFailed)
    }

    // MARK: - R06 数量上限

    func testR06_TruncatesToMaxRefs() {
        var parser = StreamingReferenceParser()
        _ = parser.feed("好\n<<refs:[\"m1\",\"m2\",\"m3\",\"m4\"]>>")
        let output = parser.finish()

        XCTAssertEqual(output.citations.count, StreamingReferenceParser.maxRefs)
        XCTAssertEqual(output.citations, ["m1", "m2", "m3"])
    }

    // MARK: - R07 超长标记

    func testR07_OversizedTagKeepsRaw() {
        let payload = String(repeating: "a", count: 600)
        let raw = "正文\n<<refs:[\"\(payload)\"]>>"
        var parser = StreamingReferenceParser()
        _ = parser.feed(raw)
        let output = parser.finish()

        XCTAssertEqual(output.visibleText, raw)
        XCTAssertEqual(output.citations, [])
        XCTAssertTrue(output.parseFailed)
    }

    // MARK: - R09 剥离前后字符级一致

    func testR09_VisibleTextIsExactPrefix() {
        let raw = "这是回答的第一段。\n第二段也保留。\n<<refs:[\"m9\"]>>"
        var parser = StreamingReferenceParser()
        _ = parser.feed(raw)
        let output = parser.finish()

        XCTAssertTrue(raw.hasPrefix(output.visibleText))
        XCTAssertTrue(raw.dropFirst(output.visibleText.count).hasPrefix(StreamingReferenceParser.tagOpen))
        XCTAssertEqual(output.citations, ["m9"])
    }

    // MARK: - R12 解析异常不丢正文

    func testR12_InvalidJSONKeepsRaw() {
        let raw = "正常回复\n<<refs:[bad]>>"
        var parser = StreamingReferenceParser()
        _ = parser.feed(raw)
        let output = parser.finish()

        XCTAssertEqual(output.visibleText, raw, "解析失败必须保留原文")
        XCTAssertEqual(output.citations, [])
        XCTAssertTrue(output.parseFailed)
    }

    // MARK: - R14 空引用数组

    func testR14_EmptyArrayStripsTag() {
        var parser = StreamingReferenceParser()
        _ = parser.feed("好的\n<<refs:[]>>")
        let output = parser.finish()

        XCTAssertEqual(output.visibleText, "好的\n")
        XCTAssertEqual(output.citations, [])
        XCTAssertFalse(output.parseFailed)
    }
}

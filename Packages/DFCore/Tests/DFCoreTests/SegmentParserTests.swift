import XCTest
@testable import DFCore

/// W2-1 多气泡协议：分段正确性、流式不泄漏分隔符、上限退化、异常不丢字。
final class SegmentParserTests: XCTestCase {

    // MARK: - 单气泡（模型不遵循协议时的退化路径）

    func testSingleBubblePassesThrough() {
        var parser = SegmentParser()
        XCTAssertEqual(parser.feed("今天有点想你"), "今天有点想你")
        XCTAssertEqual(parser.feed("，晚点聊。"), "，晚点聊。")
        XCTAssertEqual(parser.finish(), ["今天有点想你，晚点聊。"])
    }

    // MARK: - 多气泡：流式输出与最终切分一致

    func testStreamingReplacesSeparatorWithNewline() {
        var parser = SegmentParser()
        let first = parser.feed("我先说一句\n")
        XCTAssertEqual(first, "我先说一句\n")
        let second = parser.feed(SegmentProtocol.separator)
        XCTAssertEqual(second, "\n", "分隔符在流式阶段应变成换行，不得泄漏原始标记")
        let third = parser.feed("再说一句")
        XCTAssertEqual(third, "再说一句")
        XCTAssertEqual(parser.finish(), ["我先说一句", "再说一句"])
    }

    func testSeparatorSplitAcrossDeltas() {
        var parser = SegmentParser()
        var displayed = ""
        // 逐字符喂入，覆盖分隔符被切在所有可能位置的情况
        for character in "A\(SegmentProtocol.separator)B" {
            displayed += parser.feed(String(character))
        }
        XCTAssertFalse(displayed.contains("<"), "分隔符任何前缀都不得泄漏到界面")
        XCTAssertEqual(parser.finish(), ["A", "B"])
    }

    func testFiniteSegmentsPreserveOrder() {
        var parser = SegmentParser()
        _ = parser.feed("一\(SegmentProtocol.separator)二\(SegmentProtocol.separator)三")
        XCTAssertEqual(parser.finish(), ["一", "二", "三"])
    }

    // MARK: - 空段与空白

    func testEmptySegmentsAreDropped() {
        var parser = SegmentParser()
        _ = parser.feed("　\(SegmentProtocol.separator)\(SegmentProtocol.separator)好")
        XCTAssertEqual(parser.finish(), ["好"])
    }

    func testSegmentsAreTrimmed() {
        var parser = SegmentParser()
        _ = parser.feed("  第一句  \n\(SegmentProtocol.separator)\n  第二句  ")
        XCTAssertEqual(parser.finish(), ["第一句", "第二句"])
    }

    // MARK: - 上限退化

    func testExceedingMaxSegmentsKeepsTextLiteral() {
        var parser = SegmentParser()
        let joined = (0...(SegmentProtocol.maxSegments + 1))
            .map { "第\($0)段" }
            .joined(separator: SegmentProtocol.separator)
        _ = parser.feed(joined)
        let segments = parser.finish()
        XCTAssertEqual(segments.count, SegmentProtocol.maxSegments, "气泡数必须封顶")
        XCTAssertTrue(
            segments.last?.contains(SegmentProtocol.separator) == true,
            "超限部分必须原样保留为文本，不得丢弃"
        )
    }

    // MARK: - 异常不丢字

    func testIncompleteSeparatorAtEndIsPreserved() {
        var parser = SegmentParser()
        _ = parser.feed("你好<<<bu")
        XCTAssertEqual(parser.finish(), ["你好<<<bu"], "残缺分隔符按普通文本保留")
    }

    func testEmptyInputReturnsSingleEmptySegment() {
        let parser = SegmentParser()
        XCTAssertEqual(parser.finish(), [""])
        XCTAssertEqual(SegmentParser.split(""), [""])
    }

    // MARK: - 协议文本

    func testProtocolFragmentMentionsSeparatorAndLimit() {
        XCTAssertTrue(SegmentProtocol.systemFragment.contains(SegmentProtocol.separator))
        XCTAssertTrue(SegmentProtocol.systemFragment.contains("\(SegmentProtocol.maxSegments)"))
    }
}

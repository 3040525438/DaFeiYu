import XCTest
@testable import DFCore

/// D25 检索摘要纯函数：定位命中、省略号、回退与空白归一。
final class SearchSnippetTests: XCTestCase {
    func testSnippetCentersOnHitWithEllipsis() {
        let text = String(repeating: "前面的内容", count: 6)
            + "海边散步"
            + String(repeating: "后面的内容", count: 6)
        let snippet = SearchSnippet.make(text: text, query: "海边", maxLength: 20)

        XCTAssertTrue(snippet.contains("海边"), "摘要必须包含命中词")
        XCTAssertTrue(snippet.hasPrefix("…"), "命中在中间时应有前置省略号")
        XCTAssertTrue(snippet.hasSuffix("…"), "尾部被截断时应有后置省略号")
        XCTAssertLessThanOrEqual(snippet.count, 22, "摘要长度不得明显超过上限")
    }

    func testSnippetMatchesCaseInsensitively() {
        let snippet = SearchSnippet.make(text: "今天喝了 Coffee Latte", query: "coffee", maxLength: 40)
        XCTAssertTrue(snippet.lowercased().contains("coffee"))
    }

    func testSnippetFallsBackToHeadWhenQueryMissing() {
        let text = String(repeating: "无关内容", count: 20)
        let snippet = SearchSnippet.make(text: text, query: "完全不存在", maxLength: 16)
        XCTAssertEqual(snippet.count, 17, "回退为开头 16 字 + 省略号")
        XCTAssertTrue(snippet.hasSuffix("…"))
    }

    func testShortTextReturnsWholeText() {
        XCTAssertEqual(SearchSnippet.make(text: "很短的一句", query: "不存在"), "很短的一句")
    }

    func testSnippetCollapsesNewlinesAndTabs() {
        let snippet = SearchSnippet.make(text: "第一行\n\n第二行\t结束", query: "第二行", maxLength: 80)
        XCTAssertFalse(snippet.contains("\n"))
        XCTAssertFalse(snippet.contains("\t"))
        XCTAssertEqual(snippet, "第一行 第二行 结束")
    }

    func testEmptyTextReturnsEmpty() {
        XCTAssertEqual(SearchSnippet.make(text: "   \n ", query: "任意"), "")
    }

    func testEmptyQueryReturnsHead() {
        let text = String(repeating: "内容", count: 50)
        let snippet = SearchSnippet.make(text: text, query: "   ", maxLength: 10)
        XCTAssertTrue(snippet.hasSuffix("…"))
        XCTAssertLessThanOrEqual(snippet.count, 11)
    }

    func testCandidatesPreferFullQueryThenBigram() {
        let candidates = SearchSnippet.candidates(for: "摄影笔记")
        XCTAssertEqual(candidates.first, "摄影笔记")
        XCTAssertTrue(candidates.contains("摄影"))
        XCTAssertTrue(candidates.contains("影笔"))
    }
}

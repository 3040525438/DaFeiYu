import XCTest
import DFCore
@testable import DFAI

final class SSEParserTests: XCTestCase {
    func testSingleEvent() {
        let events = SSEParser.parse("data: {\"a\":1}\n\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "{\"a\":1}")
    }

    func testMultipleEvents() {
        let text = """
        data: one

        data: two

        data: [DONE]

        """
        let events = SSEParser.parse(text)
        XCTAssertEqual(events.map(\.data), ["one", "two", "[DONE]"])
    }

    func testMultiLineDataIsJoined() {
        let events = SSEParser.parse("data: line1\ndata: line2\n\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "line1\nline2")
    }

    func testCommentAndEventNameAreHandled() {
        let text = """
        : keep-alive
        event: message
        data: hello

        """
        let events = SSEParser.parse(text)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "message")
        XCTAssertEqual(events[0].data, "hello")
    }

    func testCRLFLineEndings() {
        let events = SSEParser.parse("data: hello\r\n\r\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "hello")
    }

    func testIncompleteEventIsFlushed() {
        let events = SSEParser.parse("data: no-trailing-blank-line")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "no-trailing-blank-line")
    }

    func testEmptyInputProducesNothing() {
        XCTAssertTrue(SSEParser.parse("").isEmpty)
    }
}

final class MockProviderTests: XCTestCase {
    func testMockProviderStreamsFullReply() async throws {
        let provider = MockProvider(reply: "你好呀", delayNanoseconds: 0)
        let request = ChatRequest(model: "mock", systemPrompt: "", messages: [])
        var collected = ""
        var finished = false

        for try await delta in provider.stream(request) {
            switch delta {
            case .text(let text):
                collected += text
            case .finished:
                finished = true
            case .usage:
                break
            }
        }

        XCTAssertEqual(collected, "你好呀")
        XCTAssertTrue(finished)
    }
}

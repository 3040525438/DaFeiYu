import XCTest
import DFCore
@testable import DFAI

/// D04：请求体只在调用方声明时才携带 `response_format`。
final class ProviderRequestBodyTests: XCTestCase {
    private func body(_ responseFormat: ChatResponseFormat?) throws -> [String: Any] {
        let request = ChatRequest(
            model: "test-model",
            systemPrompt: "你是大肥鱼",
            messages: [ChatTurn(role: .user, text: "在吗")],
            responseFormat: responseFormat
        )
        let data = try OpenAIWireCodec.makeBody(request)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func testNoResponseFormatWhenUnset() throws {
        let json = try body(nil)
        XCTAssertNil(json["response_format"], "未声明时不得发送 response_format")
        XCTAssertEqual(json["model"] as? String, "test-model")
    }

    func testJsonObjectResponseFormatIsEncoded() throws {
        let json = try body(.jsonObject)
        let format = json["response_format"] as? [String: Any]
        XCTAssertEqual(format?["type"] as? String, "json_object")
    }

    func testTextResponseFormatIsEncodedAsText() throws {
        let json = try body(.text)
        let format = json["response_format"] as? [String: Any]
        XCTAssertEqual(format?["type"] as? String, "text")
    }

    func testSystemPromptIsFirstMessage() throws {
        let json = try body(nil)
        let messages = json["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.first?["role"] as? String, "system")
        XCTAssertEqual(messages?.last?["role"] as? String, "user")
    }
}

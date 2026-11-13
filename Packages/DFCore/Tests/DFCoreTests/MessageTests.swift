import XCTest
@testable import DFCore

final class MessageTests: XCTestCase {
    func testStatusTransitions() {
        var message = Message(conversationID: "c1", role: .user, text: "hi", origin: .user)
        XCTAssertEqual(message.status, .draft)
        XCTAssertTrue(message.canStartSending)

        message = message.markingSending()
        XCTAssertEqual(message.status, .sending)
        XCTAssertFalse(message.canStartSending, "发送中不允许重复触发")

        message = message.markingFailed()
        XCTAssertEqual(message.status, .failed)
        XCTAssertTrue(message.canStartSending, "失败后允许重试")

        message = message.markingSent(at: 1000)
        XCTAssertEqual(message.status, .sent)
        XCTAssertEqual(message.sentAt, 1000)
        XCTAssertFalse(message.canStartSending, "已发送不允许再次发送")
    }

    func testCodingKeysUseSnakeCaseColumns() throws {
        let message = Message(conversationID: "c1", role: .assistant, text: "hi", origin: .reply)
        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json?["client_uuid"])
        XCTAssertNotNil(json?["conversation_id"])
        XCTAssertNotNil(json?["created_at"])
        XCTAssertNotNil(json?["origin"])
    }
}

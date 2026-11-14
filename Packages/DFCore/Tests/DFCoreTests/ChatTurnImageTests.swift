import XCTest
@testable import DFCore

/// D71：图片随消息发送的编码基础
final class ChatTurnImageTests: XCTestCase {
    func testImageDataURL() {
        let image = ChatImage(mimeType: "image/jpeg", base64: "Zm9v")
        XCTAssertEqual(image.dataURL, "data:image/jpeg;base64,Zm9v")
    }

    func testTurnKeepsImages() {
        let turn = ChatTurn(
            role: .user,
            text: "看看这张图",
            images: [ChatImage(mimeType: "image/png", base64: "YmFy")]
        )
        XCTAssertEqual(turn.images.count, 1)
        XCTAssertEqual(turn.images.first?.mimeType, "image/png")
    }

    func testLegacyTurnWithoutImagesDecodes() throws {
        let json = "{\"role\":\"user\",\"text\":\"旧数据\"}"
        let turn = try JSONDecoder().decode(ChatTurn.self, from: Data(json.utf8))
        XCTAssertEqual(turn.text, "旧数据")
        XCTAssertTrue(turn.images.isEmpty, "历史消息没有 images 字段也必须能解码")
    }

    func testTurnRoundTrip() throws {
        let turn = ChatTurn(
            role: .user,
            text: "在吗",
            images: [ChatImage(mimeType: "image/jpeg", base64: "AAA")]
        )
        let data = try JSONEncoder().encode(turn)
        let decoded = try JSONDecoder().decode(ChatTurn.self, from: data)
        XCTAssertEqual(decoded, turn)
    }
}

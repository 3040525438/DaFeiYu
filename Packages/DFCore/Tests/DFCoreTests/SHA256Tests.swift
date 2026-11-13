import XCTest
@testable import DFCore

final class SHA256Tests: XCTestCase {
    func testEmptyString() {
        XCTAssertEqual(
            SHA256.hash(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func testABC() {
        XCTAssertEqual(
            SHA256.hash("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testLongerThanOneBlock() {
        let input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        XCTAssertEqual(
            SHA256.hash(input),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
    }

    func testChineseTextIsStable() {
        let first = SHA256.hash("大肥鱼")
        let second = SHA256.hash("大肥鱼")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64)
    }
}

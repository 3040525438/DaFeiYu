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

    // MARK: - 增量哈希（本地模型大文件校验）

    func testHasherMatchesOneShotForAllBoundaryLengths() {
        for length in 0...140 {
            let data = Data((0..<length).map { UInt8(($0 &* 37) & 0xff) })
            var hasher = SHA256.Hasher()
            hasher.update(data)
            XCTAssertEqual(hasher.finalize(), SHA256.hash(data), "长度 \(length) 的增量哈希不一致")
        }
    }

    func testHasherMatchesOneShotWithUnevenChunks() {
        let data = Data((0..<10_000).map { UInt8(($0 &* 17) & 0xff) })
        var hasher = SHA256.Hasher()
        var index = 0
        var step = 1
        while index < data.count {
            let end = min(index + step, data.count)
            hasher.update(data.subdata(in: index..<end))
            index = end
            step = step % 997 + 1
        }
        XCTAssertEqual(hasher.finalize(), SHA256.hash(data))
    }

    func testHasherEmptyInput() {
        var hasher = SHA256.Hasher()
        XCTAssertEqual(
            hasher.finalize(),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }
}

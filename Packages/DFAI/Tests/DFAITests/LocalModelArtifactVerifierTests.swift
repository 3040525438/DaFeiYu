import XCTest
import DFCore
@testable import DFAI

/// N-18 前置：本地模型文件体检（真实文件头 + 流式 SHA-256）。
final class LocalModelArtifactVerifierTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFModelCheck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func writeFile(name: String, data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testInspectValidGGUF() throws {
        var data = Data("GGUF".utf8)
        data.append(Data(repeating: 0x2a, count: 4096))
        let url = try writeFile(name: "model.gguf", data: data)

        let check = try LocalModelArtifactVerifier.inspect(url: url)
        XCTAssertTrue(check.exists)
        XCTAssertEqual(check.format, "gguf")
        XCTAssertEqual(check.byteSize, Int64(data.count))
        XCTAssertEqual(check.sha256, SHA256.hash(data))
        XCTAssertTrue(check.problems.isEmpty)
        XCTAssertTrue(check.isReadyForLoad)
    }

    func testInspectMatchesExpectedSHA() throws {
        var data = Data("GGUF".utf8)
        data.append(Data(repeating: 0x01, count: 128))
        let url = try writeFile(name: "model2.gguf", data: data)

        let good = try LocalModelArtifactVerifier.inspect(
            url: url,
            expectedSHA256: SHA256.hash(data).uppercased()
        )
        XCTAssertTrue(good.problems.isEmpty, "大小写不同的登记值也应匹配")

        let bad = try LocalModelArtifactVerifier.inspect(
            url: url,
            expectedSHA256: "0000000000000000000000000000000000000000000000000000000000000000"
        )
        XCTAssertFalse(bad.problems.isEmpty)
        XCTAssertFalse(bad.isReadyForLoad)
    }

    func testInspectRejectsUnknownFormat() throws {
        let url = try writeFile(name: "fake.bin", data: Data("JUNK".utf8) + Data(repeating: 0, count: 32))
        let check = try LocalModelArtifactVerifier.inspect(url: url)
        XCTAssertNil(check.format)
        XCTAssertTrue(check.problems.contains { $0.contains("文件头") })
        XCTAssertFalse(check.isReadyForLoad)
    }

    func testInspectRejectsEmptyFile() throws {
        let url = try writeFile(name: "empty.gguf", data: Data())
        let check = try LocalModelArtifactVerifier.inspect(url: url)
        XCTAssertEqual(check.byteSize, 0)
        XCTAssertTrue(check.problems.contains { $0.contains("为空") })
        XCTAssertFalse(check.isReadyForLoad)
    }

    func testInspectMissingFile() throws {
        let url = root.appendingPathComponent("missing.gguf")
        let check = try LocalModelArtifactVerifier.inspect(url: url)
        XCTAssertFalse(check.exists)
        XCTAssertEqual(check.problems, ["模型文件不存在"])
        XCTAssertFalse(check.isReadyForLoad)
    }

    func testInspectStreamsLargeFile() throws {
        var data = Data("GGUF".utf8)
        data.append(Data(repeating: 0x7f, count: LocalModelArtifactVerifier.chunkSize * 2 + 123))
        let url = try writeFile(name: "large.gguf", data: data)

        let check = try LocalModelArtifactVerifier.inspect(url: url)
        XCTAssertEqual(check.sha256, SHA256.hash(data), "分块哈希必须与整块一致")
        XCTAssertEqual(check.byteSize, Int64(data.count))
    }
}

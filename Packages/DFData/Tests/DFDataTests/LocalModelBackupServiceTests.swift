import XCTest
import GRDB
import DFCore
@testable import DFData

/// D61：本地模型独立备份（勾选、校验和、清单、失败清理）
final class LocalModelBackupServiceTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var repo: GRDBLocalModelRepository!
    private let now: Int64 = 2_000_000

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFModelBackup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        repo = GRDBLocalModelRepository(database: database)
    }

    override func tearDownWithError() throws {
        repo = nil
        database = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeService() -> LocalModelBackupService {
        LocalModelBackupService(database: database, now: { self.now })
    }

    private func modelsDirectory() -> URL {
        database.paths.workspace.appendingPathComponent("Models", isDirectory: true)
    }

    @discardableResult
    private func seedFile(_ name: String, data: Data) throws -> URL {
        let directory = modelsDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func record(
        id: String,
        name: String,
        data: Data,
        sha256: String? = nil,
        verified: Bool = false
    ) -> LocalModelRecord {
        LocalModelRecord(
            id: id,
            name: name,
            family: "test",
            quantization: "Q4_K_M",
            format: "gguf",
            fileRelPath: "\(id).gguf",
            byteSize: Int64(data.count),
            sha256: sha256 ?? SHA256.hash(data),
            sourceURL: "https://example.com/\(id).gguf",
            version: "1.0",
            status: .ready,
            downloadedBytes: Int64(data.count),
            lastVerifiedAt: verified ? 1 : nil,
            createdAt: 1,
            updatedAt: 1
        )
    }

    private func backupDirectories() -> [String] {
        let path = database.paths.workspace
            .appendingPathComponent(LocalModelBackupService.directoryRootName, isDirectory: true)
            .path
        return (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    // MARK: - 正常路径

    func testBackupCopiesSelectedModelAndWritesManifest() async throws {
        let data = Data(repeating: 7, count: 4096)
        try seedFile("m1.gguf", data: data)
        _ = try await repo.save(record(id: "m1", name: "小模型", data: data))

        let result = try await makeService().backup(selectedIDs: ["m1"])

        XCTAssertEqual(result.id, "local-models-\(now)")
        XCTAssertEqual(result.included.map(\.id), ["m1"])
        XCTAssertEqual(result.copiedBytes, Int64(data.count))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.directory.path))

        let copied = result.directory.appendingPathComponent("m1.gguf")
        XCTAssertEqual(try Data(contentsOf: copied), data)

        let manifest = try makeService().readManifest(directory: result.directory)
        XCTAssertEqual(manifest.createdAt, now)
        XCTAssertEqual(manifest.entries.count, 1)
        XCTAssertEqual(manifest.entries.first?.sha256, SHA256.hash(data))
        XCTAssertEqual(manifest.entries.first?.version, "1.0")
        XCTAssertEqual(manifest.entries.first?.sourceURL, "https://example.com/m1.gguf")
        XCTAssertEqual(manifest.entries.first?.fileName, "m1.gguf")
    }

    func testUnselectedModelIsExcludedButStillReported() async throws {
        let data = Data(repeating: 1, count: 100)
        try seedFile("m1.gguf", data: data)
        _ = try await repo.save(record(id: "m1", name: "未选模型", data: data))
        let other = Data(repeating: 2, count: 200)
        try seedFile("m2.gguf", data: other)
        _ = try await repo.save(record(id: "m2", name: "已选模型", data: other))

        let result = try await makeService().backup(selectedIDs: ["m2"])

        XCTAssertEqual(result.included.map(\.id), ["m2"])
        XCTAssertEqual(
            result.excluded.first { $0.id == "m1" }?.reason,
            .notSelected
        )
    }

    func testSecondBackupInSameMillisGetsSuffix() async throws {
        let data = Data(repeating: 3, count: 64)
        try seedFile("m1.gguf", data: data)
        _ = try await repo.save(record(id: "m1", name: "小模型", data: data))

        let service = makeService()
        let first = try await service.backup(selectedIDs: ["m1"])
        let second = try await service.backup(selectedIDs: ["m1"])

        XCTAssertNotEqual(first.directory.path, second.directory.path)
        XCTAssertEqual(second.directory.lastPathComponent, "local-models-\(now)-2")
    }

    // MARK: - 失败与清理

    func testChecksumMismatchFailsAndLeavesNoDirectory() async throws {
        let data = Data(repeating: 4, count: 128)
        try seedFile("m1.gguf", data: data)
        // 登记值与真实文件不一致：复制前必须被拦下
        _ = try await repo.save(
            record(
                id: "m1",
                name: "损坏模型",
                data: data,
                sha256: String(repeating: "0", count: 64)
            )
        )

        do {
            _ = try await makeService().backup(selectedIDs: ["m1"])
            XCTFail("校验和不一致必须失败")
        } catch let error as LocalModelBackupError {
            XCTAssertEqual(error, .checksumMismatch("损坏模型"))
        }
        XCTAssertTrue(backupDirectories().isEmpty, "失败后不能留下半成品目录")
    }

    func testMissingFileFailsAndLeavesNoDirectory() async throws {
        let data = Data(repeating: 5, count: 64)
        // 只登记不落文件
        _ = try await repo.save(record(id: "m1", name: "丢失模型", data: data))

        do {
            _ = try await makeService().backup(selectedIDs: ["m1"])
            XCTFail("文件缺失必须失败")
        } catch let error as LocalModelBackupError {
            XCTAssertEqual(error, .fileMissing("丢失模型"))
        }
        XCTAssertTrue(backupDirectories().isEmpty)
    }

    func testEmptySelectionThrowsWithoutCreatingDirectory() async throws {
        do {
            _ = try await makeService().backup(selectedIDs: [])
            XCTFail("没有可备份模型时必须报错")
        } catch let error as LocalModelBackupError {
            XCTAssertEqual(error, .emptySelection)
        }
        XCTAssertTrue(backupDirectories().isEmpty)
    }

    func testUnreadyModelCannotBeBackedUp() async throws {
        let data = Data(repeating: 6, count: 64)
        try seedFile("m1.gguf", data: data)
        var downloading = record(id: "m1", name: "下载中", data: data)
        downloading.status = .downloading
        _ = try await repo.save(downloading)

        do {
            _ = try await makeService().backup(selectedIDs: ["m1"])
            XCTFail("未就绪模型必须拒绝")
        } catch let error as LocalModelBackupError {
            XCTAssertEqual(error, .emptySelection)
        }
    }
}

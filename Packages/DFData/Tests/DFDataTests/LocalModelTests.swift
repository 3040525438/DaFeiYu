import XCTest
import GRDB
import DFCore
@testable import DFData

/// W5-1 / W5-2 / W5-5 / W5-6：本地模型注册、下载状态、上下文实测与事件记录。
final class LocalModelTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var repo: GRDBLocalModelRepository!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFLocalModel-\(UUID().uuidString)", isDirectory: true)
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

    private func makeModel(
        _ id: String,
        name: String = "本地模型",
        byteSize: Int64 = 1000,
        sha: String? = nil,
        status: LocalModelStatus = .notDownloaded
    ) -> LocalModelRecord {
        LocalModelRecord(
            id: id,
            name: name,
            family: "test",
            byteSize: byteSize,
            sha256: sha,
            status: status,
            createdAt: 100,
            updatedAt: 100
        )
    }

    func testSaveAndLoad() async throws {
        _ = try await repo.save(makeModel("m1", name: " 小模型 "))
        let loaded = try await repo.model(id: "m1")
        XCTAssertEqual(loaded?.name, "小模型", "名称必须去首尾空白")
        XCTAssertEqual(loaded?.status, .notDownloaded)
        XCTAssertEqual(loaded?.wifiOnly, true)
    }

    func testSaveRejectsEmptyNameAndBadProgress() async throws {
        do {
            _ = try await repo.save(makeModel("m1", name: "   "))
            XCTFail("空名称必须拒绝")
        } catch let error as LocalModelError {
            XCTAssertEqual(error, .emptyName)
        }

        var broken = makeModel("m2", byteSize: 100)
        broken.downloadedBytes = 200
        do {
            _ = try await repo.save(broken)
            XCTFail("下载字节超过总大小必须拒绝")
        } catch let error as LocalModelError {
            XCTAssertEqual(error, .invalidProgress)
        }
    }

    func testDuplicateSHAIsRejected() async throws {
        _ = try await repo.save(makeModel("m1", sha: "sha-same"))
        do {
            _ = try await repo.save(makeModel("m2", sha: "sha-same"))
            XCTFail("同一校验和不得登记给两个模型")
        } catch {
            XCTAssertTrue(String(describing: error).contains("已登记"))
        }
    }

    func testUpdateDownloadClampsBytes() async throws {
        _ = try await repo.save(makeModel("m1", byteSize: 100))
        try await repo.updateDownload(id: "m1", status: .downloading, downloadedBytes: 150, at: 200)

        let model = try await repo.model(id: "m1")
        XCTAssertEqual(model?.status, .downloading)
        XCTAssertEqual(model?.downloadedBytes, 100, "已下载字节必须夹到总大小")
        XCTAssertEqual(model?.progress, 1.0)
    }

    func testModelsFilteredByStatus() async throws {
        _ = try await repo.save(makeModel("m1", status: .ready))
        _ = try await repo.save(makeModel("m2", status: .failed))
        _ = try await repo.save(makeModel("m3", status: .ready))

        let ready = try await repo.models(status: .ready)
        XCTAssertEqual(Set(ready.map(\.id)), ["m1", "m3"])
    }

    func testContextProbeWritesLengthAndEvent() async throws {
        _ = try await repo.save(makeModel("m1"))
        try await repo.recordContextProbe(id: "m1", contextTokens: 8192, elapsedMs: 120, at: 500)

        let model = try await repo.model(id: "m1")
        XCTAssertEqual(model?.contextLength, 8192, "上下文长度必须来自实测")

        let events = try await repo.events(modelID: "m1", limit: 10)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, "context_probe")
        XCTAssertEqual(events[0].contextTokens, 8192)
        XCTAssertEqual(events[0].elapsedMs, 120)
    }

    func testMarkVerifiedSetsTimestamp() async throws {
        _ = try await repo.save(makeModel("m1"))
        try await repo.markVerified(id: "m1", sha256: "sha-abc", at: 900)
        let model = try await repo.model(id: "m1")
        XCTAssertEqual(model?.sha256, "sha-abc")
        XCTAssertEqual(model?.lastVerifiedAt, 900)
    }

    func testEventsOrderedAndLimited() async throws {
        _ = try await repo.save(makeModel("m1"))
        for index in 0..<5 {
            try await repo.recordEvent(
                modelID: "m1", kind: "generate", detail: "第\(index)次",
                contextTokens: nil, elapsedMs: index * 10, at: Int64(1000 + index)
            )
        }
        let events = try await repo.events(modelID: "m1", limit: 3)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.map(\.createdAt), [1004, 1003, 1002], "按时间倒序")
    }

    func testTotalBytesCountsOnlyReadyModels() async throws {
        _ = try await repo.save(makeModel("m1", byteSize: 300, status: .ready))
        _ = try await repo.save(makeModel("m2", byteSize: 700, status: .ready))
        _ = try await repo.save(makeModel("m3", byteSize: 5000, status: .downloading))

        let total = try await repo.totalBytes()
        XCTAssertEqual(total, 1000)
    }

    func testDeleteRemovesEvents() async throws {
        _ = try await repo.save(makeModel("m1"))
        try await repo.recordEvent(modelID: "m1", kind: "load", detail: "", contextTokens: nil, elapsedMs: nil, at: 1)
        try await repo.delete(id: "m1")

        let events = try await repo.events(modelID: "m1", limit: 10)
        XCTAssertTrue(events.isEmpty, "事件必须随模型级联删除")
        let model = try await repo.model(id: "m1")
        XCTAssertNil(model)
    }
}

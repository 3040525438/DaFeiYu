import XCTest
import Foundation
import DFCore
@testable import DFAI

/// 本地模型下载器测试（W5 / D58–D61）
final class LocalModelDownloaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFModel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - 夹具

    private let payload = Data((0..<10).map { UInt8($0) })

    private func makeModel(
        sha256: String? = nil,
        byteSize: Int64? = nil,
        wifiOnly: Bool = true
    ) -> LocalModelRecord {
        LocalModelRecord(
            id: "m1",
            name: "测试模型",
            family: "test",
            quantization: "q4",
            format: "gguf",
            fileRelPath: "m1.gguf",
            byteSize: byteSize ?? Int64(payload.count),
            sha256: sha256 ?? SHA256.hash(payload),
            sourceURL: "https://example.com/m1.gguf",
            status: .notDownloaded,
            wifiOnly: wifiOnly,
            createdAt: 1,
            updatedAt: 1
        )
    }

    private func makeDownloader(
        store: FakeModelStore,
        fetcher: StubFetcher,
        wifi: Bool = true
    ) -> LocalModelDownloader {
        LocalModelDownloader(
            repository: store,
            fetcher: fetcher,
            network: StubNetworkGate(wifi: wifi),
            rootDirectory: root,
            maxChunkBytes: 4,
            progressStepBytes: 1,
            now: { 1_000 }
        )
    }

    // MARK: - 下载与校验

    func testDownloadsChunksAndVerifiesChecksum() async throws {
        let store = FakeModelStore(models: [makeModel()])
        let fetcher = StubFetcher(payload: payload)
        let downloader = makeDownloader(store: store, fetcher: fetcher)

        let model = try await downloader.download(id: "m1")

        XCTAssertEqual(model.status, .ready)
        XCTAssertEqual(model.downloadedBytes, Int64(payload.count))
        XCTAssertEqual(model.sha256, SHA256.hash(payload))
        XCTAssertNotNil(model.lastVerifiedAt)
        XCTAssertEqual(fetcher.offsets, [0, 4, 8])

        let fileURL = root.appendingPathComponent("m1.gguf")
        let written = try Data(contentsOf: fileURL)
        XCTAssertEqual(written, payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("m1.part").path))
    }

    func testResumesFromExistingPartFile() async throws {
        let store = FakeModelStore(models: [makeModel()])
        let fetcher = StubFetcher(payload: payload)
        let downloader = makeDownloader(store: store, fetcher: fetcher)
        try payload.prefix(4).write(to: root.appendingPathComponent("m1.part"))

        let model = try await downloader.download(id: "m1")

        XCTAssertEqual(model.status, .ready)
        XCTAssertEqual(fetcher.offsets, [4, 8])
        let resumedData = try Data(contentsOf: root.appendingPathComponent("m1.gguf"))
        XCTAssertEqual(resumedData, payload)
    }

    func testNetworkFailureKeepsPartForResume() async throws {
        let store = FakeModelStore(models: [makeModel()])
        let fetcher = StubFetcher(payload: payload)
        fetcher.failOnCall = 2
        let downloader = makeDownloader(store: store, fetcher: fetcher)

        do {
            _ = try await downloader.download(id: "m1")
            XCTFail("应该失败")
        } catch {
            // 预期失败
        }

        let failed = await store.snapshot(id: "m1")
        XCTAssertEqual(failed?.status, .failed)
        let partURL = root.appendingPathComponent("m1.part")
        let partData = try Data(contentsOf: partURL)
        XCTAssertEqual(partData.count, 4)

        // 继续下载：从断点 4 开始
        fetcher.failOnCall = nil
        let resumed = try await downloader.resume(id: "m1")
        XCTAssertEqual(resumed.status, .ready)
        let finalData = try Data(contentsOf: root.appendingPathComponent("m1.gguf"))
        XCTAssertEqual(finalData, payload)
    }

    func testWifiOnlyBlocksOnCellular() async throws {
        let store = FakeModelStore(models: [makeModel()])
        let fetcher = StubFetcher(payload: payload)
        let downloader = makeDownloader(store: store, fetcher: fetcher, wifi: false)

        do {
            _ = try await downloader.download(id: "m1")
            XCTFail("仅 Wi-Fi 时应拒绝下载")
        } catch let error as LocalModelDownloadError {
            XCTAssertEqual(error, .wifiRequired("测试模型"))
        }

        let model = await store.snapshot(id: "m1")
        XCTAssertEqual(model?.status, .notDownloaded)
        XCTAssertTrue(fetcher.offsets.isEmpty)
    }

    func testChecksumMismatchFailsAndDeletesPart() async throws {
        let store = FakeModelStore(models: [makeModel(sha256: String(repeating: "0", count: 64))])
        let fetcher = StubFetcher(payload: payload)
        let downloader = makeDownloader(store: store, fetcher: fetcher)

        do {
            _ = try await downloader.download(id: "m1")
            XCTFail("校验和不一致应失败")
        } catch let error as LocalModelDownloadError {
            if case .checksumMismatch = error {} else {
                XCTFail("错误类型不对：\(error)")
            }
        }

        let model = await store.snapshot(id: "m1")
        XCTAssertEqual(model?.status, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("m1.part").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("m1.gguf").path))
    }

    func testMissingChecksumIsRejected() async throws {
        let store = FakeModelStore(models: [makeModel(sha256: "")])
        let fetcher = StubFetcher(payload: payload)
        let downloader = makeDownloader(store: store, fetcher: fetcher)

        do {
            _ = try await downloader.download(id: "m1")
            XCTFail("缺少校验和应拒绝")
        } catch let error as LocalModelDownloadError {
            XCTAssertEqual(error, .missingChecksum("测试模型"))
        }
        XCTAssertTrue(fetcher.offsets.isEmpty)
    }

    func testServerIgnoringRangeRestartsFromZero() async throws {
        let store = FakeModelStore(models: [makeModel()])
        let fetcher = StubFetcher(payload: payload)
        fetcher.ignoreRange = true
        let downloader = makeDownloader(store: store, fetcher: fetcher)
        try payload.prefix(4).write(to: root.appendingPathComponent("m1.part"))

        let model = try await downloader.download(id: "m1")

        XCTAssertEqual(model.status, .ready)
        let finalData = try Data(contentsOf: root.appendingPathComponent("m1.gguf"))
        XCTAssertEqual(finalData, payload)
    }

    // MARK: - 校验与删除

    func testVerifyDetectsCorruption() async throws {
        let store = FakeModelStore(models: [makeModel()])
        let fetcher = StubFetcher(payload: payload)
        let downloader = makeDownloader(store: store, fetcher: fetcher)
        _ = try await downloader.download(id: "m1")

        try Data("broken".utf8).write(to: root.appendingPathComponent("m1.gguf"))
        do {
            _ = try await downloader.verify(id: "m1")
            XCTFail("文件被篡改应校验失败")
        } catch let error as LocalModelDownloadError {
            if case .checksumMismatch = error {} else {
                XCTFail("错误类型不对：\(error)")
            }
        }
        let model = await store.snapshot(id: "m1")
        XCTAssertEqual(model?.status, .failed)
    }

    func testRemoveDownloadCleansFiles() async throws {
        let store = FakeModelStore(models: [makeModel()])
        let fetcher = StubFetcher(payload: payload)
        let downloader = makeDownloader(store: store, fetcher: fetcher)
        _ = try await downloader.download(id: "m1")

        try await downloader.removeDownload(id: "m1")

        let model = await store.snapshot(id: "m1")
        XCTAssertEqual(model?.status, .notDownloaded)
        XCTAssertEqual(model?.downloadedBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("m1.gguf").path))
    }
}

// MARK: - 测试替身

struct StubNetworkGate: LocalModelNetworkGating {
    let wifi: Bool
    func isWiFi() async -> Bool { wifi }
}

final class StubFetcher: LocalModelDataFetching, @unchecked Sendable {
    private let payload: Data
    private let lock = NSLock()
    private var recordedOffsets: [Int64] = []
    private var callCount = 0

    var ignoreRange = false
    /// 第 N 次调用抛错（从 1 开始）
    var failOnCall: Int?

    init(payload: Data) {
        self.payload = payload
    }

    var offsets: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return recordedOffsets
    }

    func fetch(_ url: URL, from offset: Int64, maxBytes: Int) async throws -> LocalModelFetchResult {
        lock.lock()
        recordedOffsets.append(offset)
        callCount += 1
        let currentCall = callCount
        let shouldFail = failOnCall == currentCall
        let ignores = ignoreRange
        lock.unlock()

        if shouldFail {
            throw LocalModelDownloadError.httpStatus(500)
        }

        if ignores {
            // 模拟服务端忽略 Range：返回整份文件
            return LocalModelFetchResult(startOffset: 0, totalBytes: Int64(payload.count), data: payload)
        }
        let start = Int(offset)
        let end = min(start + maxBytes, payload.count)
        let data = payload.subdata(in: start..<end)
        return LocalModelFetchResult(
            startOffset: Int64(start),
            totalBytes: Int64(payload.count),
            data: data
        )
    }
}

actor FakeModelStore: LocalModelRepository {
    private var byID: [String: LocalModelRecord]
    private var runtimeEvents: [ModelRuntimeEvent] = []

    init(models: [LocalModelRecord]) {
        self.byID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
    }

    func snapshot(id: String) -> LocalModelRecord? {
        byID[id]
    }

    func save(_ model: LocalModelRecord) throws -> LocalModelRecord {
        byID[model.id] = model
        return model
    }

    func model(id: String) throws -> LocalModelRecord? {
        byID[id]
    }

    func all() throws -> [LocalModelRecord] {
        byID.values.sorted { $0.id < $1.id }
    }

    func models(status: LocalModelStatus) throws -> [LocalModelRecord] {
        byID.values.filter { $0.status == status }
    }

    func delete(id: String) throws {
        byID[id] = nil
    }

    func updateDownload(
        id: String,
        status: LocalModelStatus,
        downloadedBytes: Int64,
        at millis: Int64
    ) throws {
        guard var model = byID[id] else { throw LocalModelError.notFound }
        let upper = model.byteSize > 0 ? model.byteSize : downloadedBytes
        model.status = status
        model.downloadedBytes = min(max(downloadedBytes, 0), upper)
        model.updatedAt = millis
        byID[id] = model
    }

    func recordContextProbe(id: String, contextTokens: Int, elapsedMs: Int?, at millis: Int64) throws {
        try recordEvent(
            modelID: id,
            kind: "context_probe",
            detail: "实测上下文 \(contextTokens)",
            contextTokens: contextTokens,
            elapsedMs: elapsedMs,
            at: millis
        )
    }

    func markVerified(id: String, sha256: String, at millis: Int64) throws {
        guard var model = byID[id] else { throw LocalModelError.notFound }
        model.sha256 = sha256
        model.lastVerifiedAt = millis
        model.updatedAt = millis
        byID[id] = model
    }

    func recordEvent(
        modelID: String?,
        kind: String,
        detail: String,
        contextTokens: Int?,
        elapsedMs: Int?,
        at millis: Int64
    ) throws {
        runtimeEvents.append(
            ModelRuntimeEvent(
                id: UUID().uuidString,
                modelID: modelID,
                kind: kind,
                detail: detail,
                contextTokens: contextTokens,
                elapsedMs: elapsedMs,
                createdAt: millis
            )
        )
    }

    func events(modelID: String, limit: Int) throws -> [ModelRuntimeEvent] {
        Array(runtimeEvents.filter { $0.modelID == modelID }.suffix(limit))
    }

    func totalBytes() throws -> Int64 {
        byID.values.reduce(0) { $0 + $1.byteSize }
    }
}

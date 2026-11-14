import Foundation
import DFCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - 本地模型下载（W5 / D58–D61）

/// 单次拉取结果。
public struct LocalModelFetchResult: Sendable {
    /// 本次数据在文件中的真实起始位置。服务端忽略 Range 时返回 0，下载器会从头重写。
    public var startOffset: Int64
    /// 源端总字节数；未知为 nil。
    public var totalBytes: Int64?
    public var data: Data

    public init(startOffset: Int64, totalBytes: Int64?, data: Data) {
        self.startOffset = startOffset
        self.totalBytes = totalBytes
        self.data = data
    }
}

/// 数据拉取抽象：真实实现走 URLSession Range 请求；测试注入固定分片。
public protocol LocalModelDataFetching: Sendable {
    func fetch(_ url: URL, from offset: Int64, maxBytes: Int) async throws -> LocalModelFetchResult
}

/// 网络类型判断（仅 Wi-Fi 下载策略 D60）。真机由 App 层用 NWPathMonitor 实现。
public protocol LocalModelNetworkGating: Sendable {
    func isWiFi() async -> Bool
}

public struct AlwaysWiFiGate: LocalModelNetworkGating {
    public init() {}
    public func isWiFi() async -> Bool { true }
}

public enum LocalModelDownloadError: Error, Equatable, CustomStringConvertible {
    case notFound(String)
    case missingSource(String)
    case missingChecksum(String)
    case wifiRequired(String)
    case httpStatus(Int)
    case checksumMismatch(expected: String, actual: String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case fileMissing(String)
    case disk(String)

    public var description: String {
        switch self {
        case .notFound(let id): return "模型不存在：\(id)"
        case .missingSource(let name): return "模型没有下载地址：\(name)"
        case .missingChecksum(let name): return "模型缺少校验和，拒绝下载：\(name)"
        case .wifiRequired(let name): return "仅允许 Wi-Fi 下载：\(name)"
        case .httpStatus(let code): return "下载请求失败，HTTP \(code)"
        case .checksumMismatch(let expected, let actual):
            return "校验和不一致：期望 \(expected)，实际 \(actual)"
        case .sizeMismatch(let expected, let actual):
            return "文件大小不一致：期望 \(expected)，实际 \(actual)"
        case .fileMissing(let path): return "模型文件不存在：\(path)"
        case .disk(let reason): return "写入模型文件失败：\(reason)"
        }
    }
}

/// 本地模型下载器：断点续传 + 校验和 + 仅 Wi-Fi 策略 + 状态机落库。
///
/// 规则：
/// - 文件先写 `.part`，校验通过才改成正式文件名；
/// - 下载中断保留 `.part` 与已下载字节，下次从断点继续；
/// - 校验和不一致时删除 `.part`，状态置 `failed`，绝不把坏文件标成 ready；
/// - 校验和缺失直接拒绝下载（D60 完整性要求）。
public final class LocalModelDownloader: @unchecked Sendable {
    private let repository: LocalModelRepository
    private let fetcher: LocalModelDataFetching
    private let network: LocalModelNetworkGating
    private let rootDirectory: URL
    private let now: @Sendable () -> Int64
    private let maxChunkBytes: Int
    private let progressStepBytes: Int64

    public init(
        repository: LocalModelRepository,
        fetcher: LocalModelDataFetching,
        network: LocalModelNetworkGating = AlwaysWiFiGate(),
        rootDirectory: URL,
        maxChunkBytes: Int = 8 * 1024 * 1024,
        progressStepBytes: Int64 = 2 * 1024 * 1024,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.repository = repository
        self.fetcher = fetcher
        self.network = network
        self.rootDirectory = rootDirectory
        self.maxChunkBytes = max(1, maxChunkBytes)
        self.progressStepBytes = max(1, progressStepBytes)
        self.now = now
    }

    // MARK: - 下载 / 续传

    @discardableResult
    public func download(id: String) async throws -> LocalModelRecord {
        guard let model = try await repository.model(id: id) else {
            throw LocalModelDownloadError.notFound(id)
        }
        if model.status == .ready {
            return model
        }
        guard let source = model.sourceURL, let url = URL(string: source) else {
            throw LocalModelDownloadError.missingSource(model.name)
        }
        guard let expectedHash = model.sha256?.lowercased(), !expectedHash.isEmpty else {
            throw LocalModelDownloadError.missingChecksum(model.name)
        }
        if model.wifiOnly, (await network.isWiFi()) == false {
            throw LocalModelDownloadError.wifiRequired(model.name)
        }

        let partURL = partURL(for: id)
        let finalURL = finalURL(for: model)
        try ensureDirectory(partURL.deletingLastPathComponent())
        try ensureDirectory(finalURL.deletingLastPathComponent())

        var offset = fileSize(partURL)
        if model.byteSize > 0, offset > model.byteSize {
            try? FileManager.default.removeItem(at: partURL)
            offset = 0
        }

        try await repository.updateDownload(id: id, status: .downloading, downloadedBytes: offset, at: now())

        do {
            offset = try await transfer(url: url, partURL: partURL, startOffset: offset, id: id)
        } catch {
            try? await repository.updateDownload(
                id: id,
                status: .failed,
                downloadedBytes: fileSize(partURL),
                at: now()
            )
            try? await repository.recordEvent(
                modelID: id,
                kind: "error",
                detail: "下载失败：\(error)",
                contextTokens: nil,
                elapsedMs: nil,
                at: now()
            )
            throw error
        }

        if model.byteSize > 0, offset != model.byteSize {
            try await repository.updateDownload(id: id, status: .failed, downloadedBytes: offset, at: now())
            throw LocalModelDownloadError.sizeMismatch(expected: model.byteSize, actual: offset)
        }

        let actualHash: String
        do {
            actualHash = try fileHash(partURL)
        } catch {
            try await repository.updateDownload(id: id, status: .failed, downloadedBytes: offset, at: now())
            throw LocalModelDownloadError.disk("\(error)")
        }
        guard actualHash == expectedHash else {
            try? FileManager.default.removeItem(at: partURL)
            try await repository.updateDownload(id: id, status: .failed, downloadedBytes: 0, at: now())
            throw LocalModelDownloadError.checksumMismatch(expected: expectedHash, actual: actualHash)
        }

        do {
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: partURL, to: finalURL)
        } catch {
            throw LocalModelDownloadError.disk("\(error)")
        }

        try await repository.updateDownload(id: id, status: .ready, downloadedBytes: offset, at: now())
        try await repository.markVerified(id: id, sha256: actualHash, at: now())
        try? await repository.recordEvent(
            modelID: id,
            kind: "download",
            detail: "下载完成并校验通过",
            contextTokens: nil,
            elapsedMs: nil,
            at: now()
        )

        guard let updated = try await repository.model(id: id) else {
            throw LocalModelDownloadError.notFound(id)
        }
        return updated
    }

    /// 断点续传与 `download` 同义：已存在 `.part` 时从断点继续。
    @discardableResult
    public func resume(id: String) async throws -> LocalModelRecord {
        try await download(id: id)
    }

    // MARK: - 校验 / 删除

    @discardableResult
    public func verify(id: String) async throws -> LocalModelRecord {
        guard let model = try await repository.model(id: id) else {
            throw LocalModelDownloadError.notFound(id)
        }
        guard let expectedHash = model.sha256?.lowercased(), !expectedHash.isEmpty else {
            throw LocalModelDownloadError.missingChecksum(model.name)
        }
        let url = finalURL(for: model)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LocalModelDownloadError.fileMissing(url.path)
        }
        let actualHash = try fileHash(url)
        guard actualHash == expectedHash else {
            try? await repository.updateDownload(id: id, status: .failed, downloadedBytes: 0, at: now())
            throw LocalModelDownloadError.checksumMismatch(expected: expectedHash, actual: actualHash)
        }
        try await repository.markVerified(id: id, sha256: actualHash, at: now())
        guard let updated = try await repository.model(id: id) else {
            throw LocalModelDownloadError.notFound(id)
        }
        return updated
    }

    public func removeDownload(id: String) async throws {
        guard let model = try await repository.model(id: id) else {
            throw LocalModelDownloadError.notFound(id)
        }
        try? FileManager.default.removeItem(at: partURL(for: id))
        try? FileManager.default.removeItem(at: finalURL(for: model))
        try await repository.updateDownload(id: id, status: .notDownloaded, downloadedBytes: 0, at: now())
        try? await repository.recordEvent(
            modelID: id,
            kind: "unload",
            detail: "已删除本地模型文件",
            contextTokens: nil,
            elapsedMs: nil,
            at: now()
        )
    }

    // MARK: - 传输

    private func transfer(url: URL, partURL: URL, startOffset: Int64, id: String) async throws -> Int64 {
        var offset = startOffset
        var lastPersisted = startOffset
        let handle = try openHandle(partURL, truncate: startOffset == 0)
        defer { try? handle.close() }

        while true {
            let result = try await fetcher.fetch(url, from: offset, maxBytes: maxChunkBytes)

            if result.startOffset != offset {
                // 服务端不支持 Range：从头重写
                offset = result.startOffset
                try handle.truncate(atOffset: UInt64(offset))
                try handle.seek(toOffset: UInt64(offset))
                lastPersisted = offset
            }

            if result.data.isEmpty {
                break
            }

            do {
                try handle.write(contentsOf: result.data)
            } catch {
                throw LocalModelDownloadError.disk("\(error)")
            }
            offset += Int64(result.data.count)

            if offset - lastPersisted >= progressStepBytes {
                lastPersisted = offset
                try await repository.updateDownload(
                    id: id,
                    status: .downloading,
                    downloadedBytes: offset,
                    at: now()
                )
            }

            if let total = result.totalBytes, offset >= total {
                break
            }
            if result.data.count < maxChunkBytes, offset >= (result.totalBytes ?? offset) {
                break
            }
        }

        try handle.synchronize()
        try await repository.updateDownload(id: id, status: .downloading, downloadedBytes: offset, at: now())
        return offset
    }

    private func openHandle(_ url: URL, truncate: Bool) throws -> FileHandle {
        if truncate {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
        } catch {
            throw LocalModelDownloadError.disk("\(error)")
        }
        return handle
    }

    // MARK: - 文件

    private func ensureDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw LocalModelDownloadError.disk("\(error)")
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func fileHash(_ url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw LocalModelDownloadError.fileMissing(url.path)
        }
        defer { try? handle.close() }
        var hasher = SHA256.Hasher()
        while true {
            let chunk = try? handle.read(upToCount: 1024 * 1024)
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(chunk)
        }
        return hasher.finalize()
    }

    private func partURL(for id: String) -> URL {
        rootDirectory.appendingPathComponent("\(id).part")
    }

    private func finalURL(for model: LocalModelRecord) -> URL {
        let name = model.fileRelPath.isEmpty
            ? "\(model.id).\(model.format.isEmpty ? "bin" : model.format)"
            : model.fileRelPath
        return rootDirectory.appendingPathComponent(name)
    }
}

// MARK: - URLSession 实现

/// 用 Range 分段拉取，内存占用以 `maxBytes` 为上限（不会把整模型读进内存）。
public struct URLSessionLocalModelFetcher: LocalModelDataFetching {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(_ url: URL, from offset: Int64, maxBytes: Int) async throws -> LocalModelFetchResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if offset > 0 {
            let end = offset + Int64(maxBytes) - 1
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LocalModelDownloadError.httpStatus(-1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalModelDownloadError.httpStatus(http.statusCode)
        }

        let startOffset: Int64 = http.statusCode == 206 ? offset : 0
        var totalBytes: Int64?
        if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = contentRange.lastIndex(of: "/") {
            totalBytes = Int64(contentRange[contentRange.index(after: slash)...].trimmingCharacters(in: .whitespaces))
        } else if http.statusCode == 200, http.expectedContentLength > 0 {
            totalBytes = http.expectedContentLength
        }

        return LocalModelFetchResult(startOffset: startOffset, totalBytes: totalBytes, data: data)
    }
}

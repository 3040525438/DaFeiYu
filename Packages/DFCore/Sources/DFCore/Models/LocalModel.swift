import Foundation

// MARK: - 本地模型

/// 本地模型状态机。下载/校验/可用性都必须能从这里读出来（D58 / D60 / D61）。
public enum LocalModelStatus: String, Sendable, CaseIterable {
    case notDownloaded = "not_downloaded"
    case downloading
    case paused
    case ready
    case failed
}

public struct LocalModelRecord: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var family: String
    public var quantization: String
    public var format: String
    /// 模型文件相对应用支持目录的路径；未下载时为空串
    public var fileRelPath: String
    public var byteSize: Int64
    public var sha256: String?
    public var sourceURL: String?
    public var license: String?
    public var version: String
    /// 上下文长度：`nil` 表示未实测/未声明（D02 要求由实测决定）
    public var contextLength: Int?
    public var supportsVision: Bool
    public var supportsASR: Bool
    public var supportsTools: Bool
    public var status: LocalModelStatus
    public var downloadedBytes: Int64
    /// 默认仅 Wi-Fi 下载（D60）
    public var wifiOnly: Bool
    public var lastVerifiedAt: Int64?
    public var createdAt: Int64
    public var updatedAt: Int64

    /// 下载进度 0...1；字节数为 0 时返回 0，不产生 NaN
    public var progress: Double {
        guard byteSize > 0 else { return 0 }
        return min(max(Double(downloadedBytes) / Double(byteSize), 0), 1)
    }

    public var isReady: Bool { status == .ready }

    public init(
        id: String,
        name: String,
        family: String = "",
        quantization: String = "",
        format: String = "gguf",
        fileRelPath: String = "",
        byteSize: Int64 = 0,
        sha256: String? = nil,
        sourceURL: String? = nil,
        license: String? = nil,
        version: String = "",
        contextLength: Int? = nil,
        supportsVision: Bool = false,
        supportsASR: Bool = false,
        supportsTools: Bool = false,
        status: LocalModelStatus = .notDownloaded,
        downloadedBytes: Int64 = 0,
        wifiOnly: Bool = true,
        lastVerifiedAt: Int64? = nil,
        createdAt: Int64,
        updatedAt: Int64
    ) {
        self.id = id
        self.name = name
        self.family = family
        self.quantization = quantization
        self.format = format
        self.fileRelPath = fileRelPath
        self.byteSize = byteSize
        self.sha256 = sha256
        self.sourceURL = sourceURL
        self.license = license
        self.version = version
        self.contextLength = contextLength
        self.supportsVision = supportsVision
        self.supportsASR = supportsASR
        self.supportsTools = supportsTools
        self.status = status
        self.downloadedBytes = downloadedBytes
        self.wifiOnly = wifiOnly
        self.lastVerifiedAt = lastVerifiedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// 运行/探测事件：只追加，用于"是否真的跑过、上下文多大、多久"这类验收证据。
public struct ModelRuntimeEvent: Sendable, Equatable, Identifiable {
    public var id: String
    public var modelID: String?
    /// load / unload / generate / context_probe / error
    public var kind: String
    public var detail: String
    public var contextTokens: Int?
    public var elapsedMs: Int?
    public var createdAt: Int64

    public init(
        id: String,
        modelID: String?,
        kind: String,
        detail: String,
        contextTokens: Int?,
        elapsedMs: Int?,
        createdAt: Int64
    ) {
        self.id = id
        self.modelID = modelID
        self.kind = kind
        self.detail = detail
        self.contextTokens = contextTokens
        self.elapsedMs = elapsedMs
        self.createdAt = createdAt
    }
}

public enum LocalModelError: Error, Equatable, CustomStringConvertible {
    case notFound
    case emptyName
    case invalidProgress
    case invalidStatus(String)
    case notReady(String)

    public var description: String {
        switch self {
        case .notFound: return "模型不存在"
        case .emptyName: return "模型名称不能为空"
        case .invalidProgress: return "下载进度必须在 0 与总大小之间"
        case .invalidStatus(let value): return "非法的模型状态：\(value)"
        case .notReady(let name): return "模型尚未就绪：\(name)"
        }
    }
}

public protocol LocalModelRepository: Sendable {
    /// 新建或整行更新；`sha256` 不允许与其他模型重复。
    @discardableResult
    func save(_ model: LocalModelRecord) async throws -> LocalModelRecord
    func model(id: String) async throws -> LocalModelRecord?
    func all() async throws -> [LocalModelRecord]
    func models(status: LocalModelStatus) async throws -> [LocalModelRecord]
    func delete(id: String) async throws

    /// 更新下载状态与已下载字节；`downloadedBytes` 会夹到 `0...byteSize`。
    func updateDownload(
        id: String,
        status: LocalModelStatus,
        downloadedBytes: Int64,
        at millis: Int64
    ) async throws

    /// 写入实测上下文长度（D02），并记录一次 context_probe 事件。
    func recordContextProbe(id: String, contextTokens: Int, elapsedMs: Int?, at millis: Int64) async throws

    /// 校验和核验：写入 sha256 与核验时间。
    func markVerified(id: String, sha256: String, at millis: Int64) async throws

    func recordEvent(
        modelID: String?,
        kind: String,
        detail: String,
        contextTokens: Int?,
        elapsedMs: Int?,
        at millis: Int64
    ) async throws

    func events(modelID: String, limit: Int) async throws -> [ModelRuntimeEvent]
    /// 本地模型占用总字节（D66 存储分类）
    func totalBytes() async throws -> Int64
}

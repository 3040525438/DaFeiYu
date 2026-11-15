import Foundation
import GRDB
import DFCore

/// 本地模型独立备份结果
public struct LocalModelBackupResult: Sendable, Equatable {
    public var id: String
    public var directory: URL
    public var included: [LocalModelBackupEntry]
    public var excluded: [LocalModelBackupExcludedEntry]
    /// 实际复制成功的字节数（以文件大小为准）
    public var copiedBytes: Int64

    public init(
        id: String,
        directory: URL,
        included: [LocalModelBackupEntry],
        excluded: [LocalModelBackupExcludedEntry],
        copiedBytes: Int64
    ) {
        self.id = id
        self.directory = directory
        self.included = included
        self.excluded = excluded
        self.copiedBytes = copiedBytes
    }
}

public enum LocalModelBackupError: Error, Equatable, CustomStringConvertible {
    case emptySelection
    case fileMissing(String)
    case checksumMismatch(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .emptySelection: return "没有选中可备份的模型"
        case .fileMissing(let name): return "模型文件不存在：\(name)"
        case .checksumMismatch(let name): return "模型文件校验和不一致：\(name)"
        case .writeFailed(let reason): return "写入模型备份失败：\(reason)"
        }
    }
}

/// D61：把用户勾选的本地模型文件复制到独立备份目录，并写清单。
///
/// 边界：
/// - 只复制 `LocalModelBackupPolicy` 判定通过的模型（GGUF + 已就绪 + 有校验和）；
/// - 复制前流式重算 SHA-256，与登记值不一致立即失败，不留下半成品；
/// - 备份目录独立于聊天数据备份，模型可随时重新下载，不参与整体恢复；
/// - 不做密钥加密：模型文件本身不含隐私内容，且体积大。
public final class LocalModelBackupService: @unchecked Sendable {
    /// 备份根目录名（位于 `Workspace` 下）
    public static let directoryRootName = "LocalModelBackups"
    /// 清单文件名
    public static let manifestFileName = "manifest.json"
    /// 清单格式标识
    public static let manifestFormat = "dafeiyu-local-models/1"

    private let database: AppDatabase
    private let repository: GRDBLocalModelRepository
    private let now: @Sendable () -> Int64
    private let fileManager = FileManager.default

    public init(
        database: AppDatabase,
        now: @escaping @Sendable () -> Int64 = { Clock.nowMillis() }
    ) {
        self.database = database
        self.repository = GRDBLocalModelRepository(database: database)
        self.now = now
    }

    /// 模型文件源目录（与下载器一致）
    public var modelsDirectory: URL {
        database.paths.workspace.appendingPathComponent("Models", isDirectory: true)
    }

    /// 备份根目录
    public var backupsDirectory: URL {
        database.paths.workspace.appendingPathComponent(Self.directoryRootName, isDirectory: true)
    }

    /// 按用户勾选创建一次模型备份
    @discardableResult
    public func backup(
        selectedIDs: Set<String>,
        maxTotalBytes: Int64? = nil,
        at millis: Int64? = nil
    ) async throws -> LocalModelBackupResult {
        let models = try await repository.all()
        let plan = LocalModelBackupPolicy.plan(
            models: models,
            selectedIDs: selectedIDs,
            maxTotalBytes: maxTotalBytes
        )
        guard !plan.included.isEmpty else {
            throw LocalModelBackupError.emptySelection
        }

        let timestamp = millis ?? now()
        let id = "local-models-\(timestamp)"
        let directory = uniqueDirectory(base: backupsDirectory.appendingPathComponent(id, isDirectory: true))

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var copiedBytes: Int64 = 0
            var manifestEntries: [ManifestEntry] = []

            for entry in plan.included {
                let source = modelsDirectory.appendingPathComponent(entry.fileRelPath)
                guard fileManager.fileExists(atPath: source.path) else {
                    throw LocalModelBackupError.fileMissing(entry.name)
                }
                let actual = try sha256(of: source)
                guard actual == entry.sha256.lowercased() else {
                    throw LocalModelBackupError.checksumMismatch(entry.name)
                }
                let fileName = "\(entry.id).\(entry.format)"
                let destination = directory.appendingPathComponent(fileName)
                try fileManager.copyItem(at: source, to: destination)
                let size = Self.fileSize(destination)
                copiedBytes += size
                manifestEntries.append(
                    ManifestEntry(
                        id: entry.id,
                        name: entry.name,
                        version: entry.version,
                        sourceURL: entry.sourceURL,
                        sha256: entry.sha256,
                        byteSize: size,
                        format: entry.format,
                        quantization: entry.quantization,
                        fileName: fileName
                    )
                )
            }

            let manifest = Manifest(
                format: Self.manifestFormat,
                createdAt: timestamp,
                schemaVersion: database.currentSchemaVersion,
                entries: manifestEntries
            )
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: directory.appendingPathComponent(Self.manifestFileName), options: .atomic)

            return LocalModelBackupResult(
                id: id,
                directory: directory,
                included: plan.included,
                excluded: plan.excluded,
                copiedBytes: copiedBytes
            )
        } catch {
            // 失败整体清理，不留下可被误认为"可用"的半成品
            try? fileManager.removeItem(at: directory)
            if let error = error as? LocalModelBackupError { throw error }
            throw LocalModelBackupError.writeFailed(error.localizedDescription)
        }
    }

    /// 读取一次备份的清单（校验入口；文件本身是否完好由 SHA-256 决定）
    public func readManifest(directory: URL) throws -> LocalModelBackupManifest {
        let url = directory.appendingPathComponent(Self.manifestFileName)
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.format == Self.manifestFormat else {
            throw LocalModelBackupError.writeFailed("清单格式不支持：\(manifest.format)")
        }
        return LocalModelBackupManifest(
            directory: directory,
            createdAt: manifest.createdAt,
            schemaVersion: manifest.schemaVersion,
            entries: manifest.entries.map {
                LocalModelBackupManifest.Entry(
                    id: $0.id,
                    name: $0.name,
                    version: $0.version,
                    sourceURL: $0.sourceURL,
                    sha256: $0.sha256,
                    byteSize: $0.byteSize,
                    format: $0.format,
                    quantization: $0.quantization,
                    fileName: $0.fileName
                )
            }
        )
    }

    // MARK: - 内部

    private struct Manifest: Codable {
        var format: String
        var createdAt: Int64
        var schemaVersion: String
        var entries: [ManifestEntry]
    }

    private struct ManifestEntry: Codable {
        var id: String
        var name: String
        var version: String
        var sourceURL: String?
        var sha256: String
        var byteSize: Int64
        var format: String
        var quantization: String
        var fileName: String
    }

    /// 同毫秒重复备份时追加序号，避免覆盖上一次
    private func uniqueDirectory(base: URL) -> URL {
        guard fileManager.fileExists(atPath: base.path) else { return base }
        var index = 2
        while true {
            let candidate = base.deletingLastPathComponent()
                .appendingPathComponent("\(base.lastPathComponent)-\(index)", isDirectory: true)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private func sha256(of url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw LocalModelBackupError.fileMissing(url.lastPathComponent)
        }
        defer { try? handle.close() }
        var hasher = SHA256.Hasher()
        while true {
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(chunk)
        }
        return hasher.finalize().lowercased()
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// 供界面展示的备份清单
public struct LocalModelBackupManifest: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var version: String
        public var sourceURL: String?
        public var sha256: String
        public var byteSize: Int64
        public var format: String
        public var quantization: String
        public var fileName: String

        public init(
            id: String,
            name: String,
            version: String,
            sourceURL: String?,
            sha256: String,
            byteSize: Int64,
            format: String,
            quantization: String,
            fileName: String
        ) {
            self.id = id
            self.name = name
            self.version = version
            self.sourceURL = sourceURL
            self.sha256 = sha256
            self.byteSize = byteSize
            self.format = format
            self.quantization = quantization
            self.fileName = fileName
        }
    }

    public var directory: URL
    public var createdAt: Int64
    public var schemaVersion: String
    public var entries: [Entry]

    public init(directory: URL, createdAt: Int64, schemaVersion: String, entries: [Entry]) {
        self.directory = directory
        self.createdAt = createdAt
        self.schemaVersion = schemaVersion
        self.entries = entries
    }
}

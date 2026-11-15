import Foundation
import DFCore

/// 本地模型文件体检结果（N-18 前置校验，不做推理）。
public struct LocalModelArtifactCheck: Sendable, Equatable {
    public var exists: Bool
    public var byteSize: Int64
    public var sha256: String?
    /// 由文件头识别：gguf / ggml / ggjt / ggmf / ggla；nil 表示不是已知模型格式
    public var format: String?
    public var problems: [String]

    /// 只代表"文件可交给推理内核加载"，不代表内核已接入或能跑通。
    public var isReadyForLoad: Bool {
        exists && problems.isEmpty
    }

    public init(
        exists: Bool,
        byteSize: Int64,
        sha256: String?,
        format: String?,
        problems: [String]
    ) {
        self.exists = exists
        self.byteSize = byteSize
        self.sha256 = sha256
        self.format = format
        self.problems = problems
    }
}

public enum LocalModelArtifactError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)

    public var description: String {
        switch self {
        case .unreadable(let path): return "模型文件无法读取：\(path)"
        }
    }
}

/// 本地模型文件校验：存在性、大小、文件头格式、流式 SHA-256。
///
/// 说明（N-18）：推理内核尚未接入；本校验是接入前的**真实**准备工作，
/// 只回答"这个文件能不能交给内核"，不声称已具备推理能力。
public enum LocalModelArtifactVerifier {
    /// 流式读取块大小（1 MiB），避免把数 GB 模型整个读进内存
    public static let chunkSize = 1 << 20

    private static let knownMagics: [(Data, String)] = [
        (Data("GGUF".utf8), "gguf"),
        (Data("GGML".utf8), "ggml"),
        (Data("ggml".utf8), "ggml"),
        (Data("ggjt".utf8), "ggjt"),
        (Data("ggmf".utf8), "ggmf"),
        (Data("ggla".utf8), "ggla")
    ]

    public static func inspect(url: URL, expectedSHA256: String? = nil) throws -> LocalModelArtifactCheck {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return LocalModelArtifactCheck(
                exists: false,
                byteSize: 0,
                sha256: nil,
                format: nil,
                problems: ["模型文件不存在"]
            )
        }

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let byteSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw LocalModelArtifactError.unreadable(url.path)
        }
        defer { try? handle.close() }

        let header = (try? handle.read(upToCount: 4)) ?? Data()
        let format = detect(header)

        try handle.seek(toOffset: 0)
        var hasher = SHA256.Hasher()
        while true {
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(chunk)
            if Task.isCancelled { break }
        }
        let digest = hasher.finalize()

        var problems: [String] = []
        if byteSize <= 0 {
            problems.append("模型文件为空")
        }
        if format == nil {
            problems.append("文件头不是已知的 GGUF/GGML 模型格式")
        }
        if let expected = expectedSHA256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !expected.isEmpty,
           expected != digest.lowercased() {
            problems.append("SHA-256 与登记值不一致")
        }

        return LocalModelArtifactCheck(
            exists: true,
            byteSize: byteSize,
            sha256: digest,
            format: format,
            problems: problems
        )
    }

    static func detect(_ header: Data) -> String? {
        guard header.count >= 4 else { return nil }
        let prefix = header.prefix(4)
        for (magic, name) in knownMagics where prefix == magic {
            return name
        }
        return nil
    }
}

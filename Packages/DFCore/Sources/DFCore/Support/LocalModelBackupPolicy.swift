import Foundation

/// D61：本地模型「独立选择备份」的纯逻辑。
///
/// 模型文件体积大、可重新下载，因此**默认不纳入整体备份**，
/// 由用户逐项勾选；只有同时满足以下条件的模型才允许勾选：
/// - 状态为 `ready`（文件已落盘）；
/// - 有合法的 64 位 SHA-256（否则备份无法验证完整性）；
/// - 格式在支持列表内（当前为 GGUF）。
///
/// 本文件只做判定与清单生成，不触碰文件系统；复制与校验在 DFData。
public enum LocalModelCompatibility: Sendable, Equatable {
    case compatible
    case notDownloaded
    case checksumMissing
    case unsupportedFormat(String)

    public var text: String {
        switch self {
        case .compatible: return "兼容"
        case .notDownloaded: return "文件未就绪"
        case .checksumMissing: return "缺少校验和"
        case .unsupportedFormat(let format): return "格式不支持（\(format.uppercased())）"
        }
    }

    public var isCompatible: Bool {
        self == .compatible
    }
}

/// 某个模型没有进入备份计划的原因
public enum LocalModelBackupExclusion: String, Sendable, Equatable {
    case notSelected
    case notReady
    case checksumMissing
    case unsupportedFormat
    case overSizeLimit

    public var text: String {
        switch self {
        case .notSelected: return "未勾选"
        case .notReady: return "文件未就绪，下载完成后才能备份"
        case .checksumMissing: return "缺少 SHA-256，无法验证完整性"
        case .unsupportedFormat: return "当前只支持 GGUF 格式"
        case .overSizeLimit: return "超过本次备份体积上限"
        }
    }
}

/// 进入备份计划的模型条目（含版本/来源/校验和/兼容性，写入清单）
public struct LocalModelBackupEntry: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var version: String
    public var sourceURL: String?
    public var sha256: String
    public var format: String
    public var quantization: String
    public var byteSize: Int64
    public var fileRelPath: String
    /// 是否做过校验和核验（`lastVerifiedAt` 非空）
    public var isVerified: Bool
    public var compatibility: LocalModelCompatibility

    public init(
        id: String,
        name: String,
        version: String,
        sourceURL: String?,
        sha256: String,
        format: String,
        quantization: String,
        byteSize: Int64,
        fileRelPath: String,
        isVerified: Bool,
        compatibility: LocalModelCompatibility
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.sourceURL = sourceURL
        self.sha256 = sha256
        self.format = format
        self.quantization = quantization
        self.byteSize = byteSize
        self.fileRelPath = fileRelPath
        self.isVerified = isVerified
        self.compatibility = compatibility
    }
}

/// 被排除的模型
public struct LocalModelBackupExcludedEntry: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var reason: LocalModelBackupExclusion

    public init(id: String, name: String, reason: LocalModelBackupExclusion) {
        self.id = id
        self.name = name
        self.reason = reason
    }
}

/// 备份计划：勾选结果 + 排除原因 + 总体积
public struct LocalModelBackupPlan: Sendable, Equatable {
    public var included: [LocalModelBackupEntry]
    public var excluded: [LocalModelBackupExcludedEntry]
    public var totalBytes: Int64

    public init(
        included: [LocalModelBackupEntry],
        excluded: [LocalModelBackupExcludedEntry],
        totalBytes: Int64
    ) {
        self.included = included
        self.excluded = excluded
        self.totalBytes = totalBytes
    }

    public var isEmpty: Bool { included.isEmpty }
}

public enum LocalModelBackupPolicy {
    /// 当前可备份的模型格式（与下载器一致）
    public static let supportedFormats: Set<String> = ["gguf"]

    /// 可勾选的模型（界面据此控制开关）
    public static func compatibility(_ model: LocalModelRecord) -> LocalModelCompatibility {
        let format = model.format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard supportedFormats.contains(format) else {
            return .unsupportedFormat(format.isEmpty ? "unknown" : format)
        }
        guard model.status == .ready else { return .notDownloaded }
        guard isValidChecksum(model.sha256) else { return .checksumMissing }
        return .compatible
    }

    /// 校验和必须是 64 位十六进制（大小写不敏感），其余一律视为缺失
    public static func isValidChecksum(_ value: String?) -> Bool {
        guard let value else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count == 64 && trimmed.allSatisfy { $0.isHexDigit }
    }

    /// 生成备份计划：可用性 → 勾选 → 体积上限，顺序固定，结果可预测
    public static func plan(
        models: [LocalModelRecord],
        selectedIDs: Set<String>,
        maxTotalBytes: Int64? = nil
    ) -> LocalModelBackupPlan {
        // 按名称、id 排序，保证每次生成的清单顺序一致
        let sorted = models.sorted { lhs, rhs in
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.id < rhs.id
        }

        var included: [LocalModelBackupEntry] = []
        var excluded: [LocalModelBackupExcludedEntry] = []
        var total: Int64 = 0

        for model in sorted {
            let compatibility = compatibility(model)
            switch compatibility {
            case .unsupportedFormat:
                excluded.append(
                    LocalModelBackupExcludedEntry(
                        id: model.id,
                        name: model.name,
                        reason: .unsupportedFormat
                    )
                )
                continue
            case .notDownloaded:
                excluded.append(
                    LocalModelBackupExcludedEntry(id: model.id, name: model.name, reason: .notReady)
                )
                continue
            case .checksumMissing:
                excluded.append(
                    LocalModelBackupExcludedEntry(id: model.id, name: model.name, reason: .checksumMissing)
                )
                continue
            case .compatible:
                break
            }

            guard selectedIDs.contains(model.id) else {
                excluded.append(
                    LocalModelBackupExcludedEntry(id: model.id, name: model.name, reason: .notSelected)
                )
                continue
            }

            if let limit = maxTotalBytes, total + model.byteSize > limit {
                excluded.append(
                    LocalModelBackupExcludedEntry(id: model.id, name: model.name, reason: .overSizeLimit)
                )
                continue
            }

            total += model.byteSize
            included.append(
                LocalModelBackupEntry(
                    id: model.id,
                    name: model.name,
                    version: model.version,
                    sourceURL: model.sourceURL,
                    sha256: (model.sha256 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                    format: model.format.lowercased(),
                    quantization: model.quantization,
                    byteSize: model.byteSize,
                    fileRelPath: model.fileRelPath,
                    isVerified: model.lastVerifiedAt != nil,
                    compatibility: compatibility
                )
            )
        }

        return LocalModelBackupPlan(included: included, excluded: excluded, totalBytes: total)
    }
}

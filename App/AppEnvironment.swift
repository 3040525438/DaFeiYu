import Foundation
import DFCore
import DFData

/// 两个环境共用同一套代码，环境标识来自构建配置注入的 `DFEnvironment`。
/// 本文件不再提供任何"按 Bundle ID 猜测"或默认回退的入口。
typealias AppEnvironment = EnvironmentID

extension EnvironmentID {
    var displayName: String {
        switch self {
        case .production: return "大肥鱼"
        case .lab: return "大肥鱼 Lab"
        }
    }

    var bundleIdentifier: String {
        expectedBundleID
    }
}

/// 构建信息。写入目录标记时留痕，便于追溯目录是被哪个版本创建的。
enum AppBuildInfo {
    static var current: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return "\(version)+\(build)"
    }
}

/// 环境校验失败时的诊断文本：把四项证据一起展示，避免再次出现"只能靠目录名猜"的情况。
enum EnvironmentDiagnostics {
    static func text(error: Error,
                     bundleID: String?,
                     dataRoot: URL?,
                     keychainService: String?) -> String {
        var lines: [String] = []

        if let validation = error as? EnvironmentValidationError {
            lines.append(reason(for: validation))
        } else if let marker = error as? EnvironmentMarkerError {
            lines.append(reason(for: marker))
        } else {
            lines.append("错误：\(error.localizedDescription)")
        }

        lines.append("")
        lines.append("诊断信息（只读，不会自动修复）：")
        lines.append("· 实际 Bundle ID：\(bundleID ?? "（读取失败）")")
        lines.append("· 数据目录：\(dataRoot?.path ?? "（未确定）")")
        lines.append("· Keychain service：\(keychainService ?? "（未确定）")")
        lines.append("")
        lines.append("请确认安装包与环境配置是否匹配，不要手动改动数据库或目录结构。")
        return lines.joined(separator: "\n")
    }

    private static func reason(for error: EnvironmentValidationError) -> String {
        switch error {
        case .configMissing:
            return "构建配置缺少 DFEnvironment，无法确定运行环境。"
        case .configInvalid(let value):
            return "构建配置的 DFEnvironment 取值非法：\(value)。"
        case .bundleIDMissing:
            return "无法读取当前 App 的 Bundle ID。"
        case .bundleIDMismatch(let expected, let actual):
            return "Bundle ID 与环境不符：预期 \(expected)，实际 \(actual)。"
        case .signatureSuffixInvalid(let suffix):
            return "Bundle ID 的签名后缀形态非法：\(suffix)。"
        case .dataDirectoryMismatch(let expected, let actual):
            return "数据目录与环境不符：预期 \(expected)，实际 \(actual)。"
        case .databaseOutsideRoot(let path):
            return "数据库路径不在本环境目录下：\(path)。"
        case .keychainServiceMismatch(let expected, let actual):
            return "Keychain service 与环境不符：预期 \(expected)，实际 \(actual)。"
        }
    }

    private static func reason(for error: EnvironmentMarkerError) -> String {
        switch error {
        case .missing(let path):
            return "数据目录缺少归属标记，且目录内已有数据：\(path)。"
        case .mismatched(let expected, let found):
            return "数据目录归属与当前环境不符：目录属于 \(found)，当前环境是 \(expected)。"
        case .corrupted(let path):
            return "数据目录归属标记已损坏：\(path)。"
        case .notADirectory(let path):
            return "数据目录路径不是目录：\(path)。"
        case .writeFailed(let message):
            return "数据目录归属标记写入失败：\(message)。"
        }
    }
}

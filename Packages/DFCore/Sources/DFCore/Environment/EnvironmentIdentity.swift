import Foundation

/// 运行环境标识。
///
/// 唯一来源是构建配置注入的 `DFEnvironment`（见 `project.yml` 的 `DF_ENVIRONMENT_NAME`），
/// 不再根据 Bundle ID 后缀猜测，也不允许任何默认值兜底。
public enum EnvironmentID: String, Codable, Sendable, CaseIterable {
    case production
    case lab

    /// 该环境在构建配置中的预期 Bundle ID（未签名包的真实 ID）。
    public var expectedBundleID: String {
        switch self {
        case .production: return "com.dafeiyu.app"
        case .lab: return "com.dafeiyu.lab"
        }
    }

    /// 数据根目录名。两个环境完全隔离，互不读写。
    public var dataDirectoryName: String {
        switch self {
        case .production: return "DaFeiYu"
        case .lab: return "DaFeiYuLab"
        }
    }

    /// Keychain service。正式版沿用既有值以避免老用户凭据失效；实验版独立。
    public var keychainService: String {
        switch self {
        case .production: return "com.dafeiyu.app.keys"
        case .lab: return "com.dafeiyu.lab.keys"
        }
    }

    public var isLab: Bool { self == .lab }
}

/// 环境校验失败的原因。全部为 fail closed：调用方不得继续创建容器或打开数据库。
public enum EnvironmentValidationError: Error, Equatable, Sendable {
    /// Info.plist 缺少 DFEnvironment（构建配置未注入）
    case configMissing
    /// DFEnvironment 取值不在 production / lab 之内
    case configInvalid(String)
    /// 运行时拿不到 Bundle ID
    case bundleIDMissing
    /// Bundle ID 与环境声明不符（既不是预期值，也不是"预期值 + 后缀"）
    case bundleIDMismatch(expected: String, actual: String)
    /// 签名追加后缀形态非法（空、含斜杠、含空白）
    case signatureSuffixInvalid(String)
    /// 数据根目录名与环境不符
    case dataDirectoryMismatch(expected: String, actual: String)
    /// 数据库文件不在数据根目录之下
    case databaseOutsideRoot(String)
    /// Keychain service 与环境派生值不符
    case keychainServiceMismatch(expected: String, actual: String)
}

/// 已解析、但尚未完成目录与 Keychain 校验的环境身份。
public struct EnvironmentIdentity: Sendable, Equatable {
    public let environment: EnvironmentID
    public let expectedBundleID: String
    public let actualBundleID: String
    /// 仅用于诊断展示（例如个人 Team 签名追加的 `424HCPR7NT`）。
    /// 不参与环境判定，也不放宽任何校验。
    public let signatureSuffix: String?

    public init(environment: EnvironmentID, expectedBundleID: String,
                actualBundleID: String, signatureSuffix: String?) {
        self.environment = environment
        self.expectedBundleID = expectedBundleID
        self.actualBundleID = actualBundleID
        self.signatureSuffix = signatureSuffix
    }

    /// 从构建期配置解析环境。缺失或异常一律抛错，绝不回退到 production。
    public static func resolve(info: [String: Any], actualBundleID: String?) throws -> EnvironmentIdentity {
        guard let raw = info["DFEnvironment"] as? String else {
            throw EnvironmentValidationError.configMissing
        }
        guard let environment = EnvironmentID(rawValue: raw) else {
            throw EnvironmentValidationError.configInvalid(raw)
        }
        guard let actual = actualBundleID, !actual.isEmpty else {
            throw EnvironmentValidationError.bundleIDMissing
        }

        let expected = environment.expectedBundleID
        var suffix: String?
        if actual != expected {
            guard actual.hasPrefix(expected + ".") else {
                throw EnvironmentValidationError.bundleIDMismatch(expected: expected, actual: actual)
            }
            let candidate = String(actual.dropFirst(expected.count + 1))
            guard !candidate.isEmpty,
                  !candidate.contains("/"),
                  !candidate.contains(where: { $0.isWhitespace }) else {
                throw EnvironmentValidationError.signatureSuffixInvalid(candidate)
            }
            suffix = candidate
        }

        return EnvironmentIdentity(
            environment: environment,
            expectedBundleID: expected,
            actualBundleID: actual,
            signatureSuffix: suffix
        )
    }

    /// 目录名、库路径归属、Keychain service 的三重一致性校验。
    /// 无论 `signatureSuffix` 是否存在，这里的断言完全相同。
    public func validate(root: URL, databaseURL: URL, keychainService: String) throws {
        guard root.lastPathComponent == environment.dataDirectoryName else {
            throw EnvironmentValidationError.dataDirectoryMismatch(
                expected: environment.dataDirectoryName,
                actual: root.lastPathComponent
            )
        }
        guard databaseURL.path.hasPrefix(root.path + "/") else {
            throw EnvironmentValidationError.databaseOutsideRoot(databaseURL.path)
        }
        guard keychainService == environment.keychainService else {
            throw EnvironmentValidationError.keychainServiceMismatch(
                expected: environment.keychainService,
                actual: keychainService
            )
        }
    }
}

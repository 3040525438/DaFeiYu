import Foundation

/// 两个环境共用同一套代码，只在运行时区分。
/// 判定依据是 Bundle ID 后缀，避免依赖手写的编译宏。
enum AppEnvironment: String {
    case production
    case lab

    static func resolve(bundleID: String?) -> AppEnvironment {
        guard let bundleID, !bundleID.isEmpty else { return .production }
        return bundleID.hasSuffix(".lab") ? .lab : .production
    }

    var isLab: Bool {
        self == .lab
    }

    var bundleIdentifier: String {
        switch self {
        case .production: return "com.dafeiyu.app"
        case .lab: return "com.dafeiyu.lab"
        }
    }

    var displayName: String {
        switch self {
        case .production: return "大肥鱼"
        case .lab: return "大肥鱼 Lab"
        }
    }

    /// 数据根目录名。两个环境完全隔离，互不读写。
    var dataDirectoryName: String {
        switch self {
        case .production: return "DaFeiYu"
        case .lab: return "DaFeiYuLab"
        }
    }

    /// Keychain service。隔离密钥，实验版拿不到正式版的 API Key。
    var keychainService: String {
        switch self {
        case .production: return "com.dafeiyu.app.keys"
        case .lab: return "com.dafeiyu.lab.keys"
        }
    }
}

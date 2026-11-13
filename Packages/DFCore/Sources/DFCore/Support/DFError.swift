import Foundation

public enum DFError: LocalizedError, Equatable {
    case notConfigured(String)
    case invalidURL(String)
    case http(status: Int, message: String)
    case decoding(String)
    case network(String)
    case unsupported(String)
    case database(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let what):
            return "尚未配置：\(what)"
        case .invalidURL(let value):
            return "地址格式不正确：\(value)"
        case .http(let status, let message):
            return "服务返回 \(status)：\(message)"
        case .decoding(let detail):
            return "数据解析失败：\(detail)"
        case .network(let detail):
            return "网络错误：\(detail)"
        case .unsupported(let detail):
            return "当前环境不支持：\(detail)"
        case .database(let detail):
            return "本地数据库错误：\(detail)"
        case .cancelled:
            return "已取消"
        }
    }
}

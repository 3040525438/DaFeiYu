import Foundation

// MARK: - 诊断与存储（W10-3 / D66、D70）

/// 存储占用分类。只统计本地目录，不做删除动作。
public struct StorageUsageItem: Sendable, Equatable, Identifiable, Codable {
    public var key: String
    public var title: String
    public var bytes: Int64

    public var id: String { key }

    public init(key: String, title: String, bytes: Int64) {
        self.key = key
        self.title = title
        self.bytes = bytes
    }
}

public struct StorageUsage: Sendable, Equatable, Codable {
    public var items: [StorageUsageItem]

    public init(items: [StorageUsageItem]) {
        self.items = items
    }

    public var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.bytes }
    }

    /// 空间预警阈值（剩余空间低于 500MB 提示清理）
    public static let lowSpaceThreshold: Int64 = 500 * 1024 * 1024

    public static func humanReadable(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB"]
        var value = Double(bytes) / 1024
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return String(format: "%.1f %@", value, units[index])
    }
}

/// 诊断报告：只含计数、版本与健康结论，不含任何正文。
public struct DiagnosticReport: Sendable, Equatable, Codable {
    public var appVersion: String
    public var schemaVersion: String
    public var platform: String
    public var generatedAt: Int64
    public var counts: [String: Int]
    public var storage: StorageUsage
    public var healthy: Bool
    public var healthNotes: [String]
    public var freeBytes: Int64?

    public init(
        appVersion: String,
        schemaVersion: String,
        platform: String,
        generatedAt: Int64,
        counts: [String: Int],
        storage: StorageUsage,
        healthy: Bool,
        healthNotes: [String],
        freeBytes: Int64? = nil
    ) {
        self.appVersion = appVersion
        self.schemaVersion = schemaVersion
        self.platform = platform
        self.generatedAt = generatedAt
        self.counts = counts
        self.storage = storage
        self.healthy = healthy
        self.healthNotes = healthNotes
        self.freeBytes = freeBytes
    }

    /// 低空间预警（true 表示建议用户清理）
    public var isLowOnSpace: Bool {
        guard let freeBytes else { return false }
        return freeBytes < StorageUsage.lowSpaceThreshold
    }
}

/// 脱敏：诊断包要能外发，必须先把密钥、账号、手机号与个人目录抹掉。
public enum DiagnosticRedactor {
    private static let patterns: [(String, String)] = [
        // OpenAI 风格密钥
        (#"sk-[A-Za-z0-9_\-]{8,}"#, "sk-***"),
        // Authorization: Bearer xxx
        (#"(?i)bearer\s+[A-Za-z0-9._\-]+"#, "Bearer ***"),
        // 常见 key=value 形式
        (#"(?i)(api[_-]?key|token|secret|password)\s*[=:]\s*\S+"#, "$1=***"),
        // 邮箱
        (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "***@***"),
        // 中国大陆手机号
        (#"\b1[3-9]\d{9}\b"#, "1**********"),
        // 32 位以上十六进制（密钥/哈希）
        (#"\b[0-9a-fA-F]{32,}\b"#, "***"),
        // 个人目录
        (#"(?i)([A-Z]:\\Users\\)[^\\\s]+"#, "$1***"),
        (#"/Users/[^/\s]+"#, "/Users/***")
    ]

    public static func redact(_ text: String) -> String {
        var result = text
        for (pattern, template) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: template
            )
        }
        return result
    }
}

/// 导出为可直接阅读的 Markdown（不含正文，仅计数与结论）。
public enum DiagnosticExporter {
    public static func markdown(_ report: DiagnosticReport) -> String {
        var lines: [String] = []
        lines.append("# 大肥鱼诊断包")
        lines.append("")
        lines.append("- 生成时间：\(formatTime(report.generatedAt))")
        lines.append("- App 版本：\(report.appVersion)")
        lines.append("- 架构版本：\(report.schemaVersion)")
        lines.append("- 平台：\(report.platform)")
        lines.append("- 健康检查：\(report.healthy ? "通过" : "异常")")
        if let free = report.freeBytes {
            lines.append("- 可用空间：\(StorageUsage.humanReadable(free))\(report.isLowOnSpace ? "（偏低，建议清理）" : "")")
        }
        lines.append("")
        lines.append("## 记录计数")
        if report.counts.isEmpty {
            lines.append("- （无）")
        } else {
            for key in report.counts.keys.sorted() {
                lines.append("- \(key)：\(report.counts[key] ?? 0)")
            }
        }
        lines.append("")
        lines.append("## 存储占用")
        for item in report.storage.items {
            lines.append("- \(item.title)：\(StorageUsage.humanReadable(item.bytes))")
        }
        lines.append("- 合计：\(StorageUsage.humanReadable(report.storage.totalBytes))")
        if !report.healthNotes.isEmpty {
            lines.append("")
            lines.append("## 健康提示")
            for note in report.healthNotes {
                lines.append("- \(DiagnosticRedactor.redact(note))")
            }
        }
        lines.append("")
        lines.append("> 本文件不含聊天正文、记忆内容或密钥；如需进一步反馈请自行复核。")
        return DiagnosticRedactor.redact(lines.joined(separator: "\n"))
    }

    public static func fileName(at millis: Int64) -> String {
        "dafeiyu-diagnostics-\(millis).md"
    }

    private static func formatTime(_ millis: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

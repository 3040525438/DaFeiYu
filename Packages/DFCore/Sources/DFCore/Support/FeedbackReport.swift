import Foundation

// MARK: - 反馈与诊断报告（D70 / D53）
//
// 边界：报告只包含版本、系统版本与**计数**，不包含聊天正文、记忆正文、人格内容或密钥。
// 全部为纯函数，便于在 CI 上验证"不泄漏内容"与截断规则。

/// 生成报告所需的诊断快照（只允许放非正文信息）
public struct DiagnosticsSnapshot: Sendable, Equatable {
    public var appVersion: String
    public var buildNumber: String
    public var systemVersion: String
    public var schemaVersion: String
    /// 计数可为空：拿不到时宁可不写，也不猜
    public var messageCount: Int?
    public var attachmentCount: Int?
    public var memoryCount: Int?

    public init(
        appVersion: String,
        buildNumber: String,
        systemVersion: String,
        schemaVersion: String,
        messageCount: Int? = nil,
        attachmentCount: Int? = nil,
        memoryCount: Int? = nil
    ) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.systemVersion = systemVersion
        self.schemaVersion = schemaVersion
        self.messageCount = messageCount
        self.attachmentCount = attachmentCount
        self.memoryCount = memoryCount
    }
}

/// 反馈类型闭集
public enum FeedbackCategory: String, Sendable, Equatable, CaseIterable {
    case bug
    case suggestion
    case data
    case other

    public var displayName: String {
        switch self {
        case .bug: return "功能异常"
        case .suggestion: return "改进建议"
        case .data: return "数据问题"
        case .other: return "其他"
        }
    }
}

/// 可直接分享 / 复制的反馈报告
public struct FeedbackReport: Sendable, Equatable {
    public var category: FeedbackCategory
    public var body: String

    public init(category: FeedbackCategory, body: String) {
        self.category = category
        self.body = body
    }
}

public enum FeedbackReportBuilder {
    /// 用户描述的长度上限；超出截断而不是拒绝
    public static let maxDetailLength = 800
    /// 隐私声明固定文案：让用户明确知道报告里有什么、没有什么
    public static let privacyNotice = "本报告只包含版本与计数，不含聊天正文、记忆正文、人格内容与密钥。"

    /// 生成报告：类型 + 用户描述 + 诊断信息 + 隐私声明。
    public static func make(
        category: FeedbackCategory,
        detail: String,
        snapshot: DiagnosticsSnapshot
    ) -> FeedbackReport {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeDetail = trimmed.isEmpty
            ? "（未填写）"
            : String(trimmed.prefix(maxDetailLength))
        let body = """
        【类型】\(category.displayName)
        【描述】
        \(safeDetail)
        【诊断信息】
        \(diagnosticsText(snapshot))
        【隐私说明】\(privacyNotice)
        """
        return FeedbackReport(category: category, body: body)
    }

    /// 诊断信息文本：只输出非空项。
    public static func diagnosticsText(_ snapshot: DiagnosticsSnapshot) -> String {
        var lines: [String] = []
        let version = snapshot.buildNumber.isEmpty
            ? "v\(snapshot.appVersion)"
            : "v\(snapshot.appVersion) (\(snapshot.buildNumber))"
        lines.append("App：\(version)")
        if !snapshot.systemVersion.isEmpty {
            lines.append("系统：\(snapshot.systemVersion)")
        }
        if !snapshot.schemaVersion.isEmpty {
            lines.append("数据库版本：\(snapshot.schemaVersion)")
        }
        if let messageCount = snapshot.messageCount {
            lines.append("消息：\(messageCount) 条")
        }
        if let attachmentCount = snapshot.attachmentCount {
            lines.append("附件：\(attachmentCount) 个")
        }
        if let memoryCount = snapshot.memoryCount {
            lines.append("记忆：\(memoryCount) 条")
        }
        return lines.joined(separator: "\n")
    }
}

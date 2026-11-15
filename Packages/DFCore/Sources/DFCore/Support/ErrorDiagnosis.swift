import Foundation

// MARK: - 错误诊断（D53）
//
// 需求：错误要给"原因 + 建议 + 是否可重试"，并能导出诊断日志。
// 这里只做纯逻辑：把错误文本归类成可执行建议，不访问网络、不读数据库。
//
// 设计原则：
// - 命中优先级固定（越具体越先判），避免一条错误被归成"未知"；
// - 不把原始错误全文直接展示给用户（可能含密钥或内部路径），只给归类结论；
// - 任何分类都必须给出非空建议。

public enum ErrorCategory: String, Sendable, Equatable, CaseIterable {
    case missingAPIKey
    case authentication
    case rateLimited
    case quotaExceeded
    case timeout
    case offline
    case modelNotFound
    case contextTooLong
    case invalidRequest
    case serverError
    case budgetExceeded
    case databaseReadOnly
    case storageFull
    case backupCorrupted
    case migrationFailed
    case permissionDenied
    case unknown

    public var displayName: String {
        switch self {
        case .missingAPIKey: return "未配置密钥"
        case .authentication: return "鉴权失败"
        case .rateLimited: return "请求过于频繁"
        case .quotaExceeded: return "额度不足"
        case .timeout: return "请求超时"
        case .offline: return "网络不可用"
        case .modelNotFound: return "模型不可用"
        case .contextTooLong: return "上下文超长"
        case .invalidRequest: return "请求参数有误"
        case .serverError: return "服务端异常"
        case .budgetExceeded: return "超出预算"
        case .databaseReadOnly: return "数据库只读"
        case .storageFull: return "存储空间不足"
        case .backupCorrupted: return "备份损坏"
        case .migrationFailed: return "数据库升级未完成"
        case .permissionDenied: return "权限被拒绝"
        case .unknown: return "未知错误"
        }
    }
}

/// 一次诊断结论
public struct ErrorDiagnosis: Sendable, Equatable {
    public var category: ErrorCategory
    /// 用户能看懂的原因（不含原始错误全文）
    public var cause: String
    /// 可执行建议，至少一条
    public var suggestions: [String]
    public var isRetryable: Bool
    /// 是否需要用户去设置里操作
    public var needsUserAction: Bool

    public init(
        category: ErrorCategory,
        cause: String,
        suggestions: [String],
        isRetryable: Bool,
        needsUserAction: Bool
    ) {
        self.category = category
        self.cause = cause
        self.suggestions = suggestions.isEmpty ? ["稍后重试，或在设置中导出发送诊断信息。"] : suggestions
        self.isRetryable = isRetryable
        self.needsUserAction = needsUserAction
    }

    /// 一句话提示（界面直接展示）
    public var headline: String {
        "\(category.displayName)：\(cause)"
    }
}

public enum ErrorDiagnoser {
    /// 归类一条错误文本（通常是 `error.localizedDescription`）。
    public static func diagnose(_ message: String) -> ErrorDiagnosis {
        let text = message.lowercased()

        // 1. 本地状态类（最具体，先判）
        if text.contains("未配置") && (text.contains("密钥") || text.contains("key")) {
            return diagnosis(.missingAPIKey)
        }
        if text.contains("只读") || text.contains("readonly") || text.contains("read-only") {
            return diagnosis(.databaseReadOnly)
        }
        if text.contains("升级未完成") || text.contains("migration") || text.contains("迁移失败") {
            return diagnosis(.migrationFailed)
        }
        if text.contains("存储空间") || text.contains("no space") || text.contains("空间不足") {
            return diagnosis(.storageFull)
        }
        if (text.contains("备份") && (text.contains("损坏") || text.contains("校验")))
            || text.contains("corrupted") || text.contains("checksum mismatch") {
            return diagnosis(.backupCorrupted)
        }
        if text.contains("超出预算") || text.contains("预算已用尽") || text.contains("budget") {
            return diagnosis(.budgetExceeded)
        }

        // 2. HTTP 状态码
        if text.contains("401") || text.contains("403") || text.contains("unauthorized") || text.contains("forbidden") {
            return diagnosis(.authentication)
        }
        if text.contains("429") || text.contains("rate limit") || text.contains("too many requests") {
            return diagnosis(.rateLimited)
        }
        if text.contains("404") || text.contains("model not found") || text.contains("does not exist") {
            return diagnosis(.modelNotFound)
        }
        if text.contains("context length") || text.contains("maximum context") || text.contains("too long") {
            return diagnosis(.contextTooLong)
        }
        if text.contains("500") || text.contains("502") || text.contains("503") || text.contains("504")
            || text.contains("server error") || text.contains("internal error") {
            return diagnosis(.serverError)
        }
        if text.contains("400") || text.contains("invalid request") || text.contains("bad request") {
            return diagnosis(.invalidRequest)
        }
        if text.contains("insufficient_quota") || text.contains("quota") || text.contains("余额不足") {
            return diagnosis(.quotaExceeded)
        }

        // 3. 网络类
        if text.contains("timed out") || text.contains("timeout") || text.contains("超时") {
            return diagnosis(.timeout)
        }
        if text.contains("offline") || text.contains("not connected") || text.contains("网络") 
            || text.contains("internet") || text.contains("network connection") {
            return diagnosis(.offline)
        }

        // 4. 权限类
        if text.contains("permission") || text.contains("denied") || text.contains("权限") {
            return diagnosis(.permissionDenied)
        }

        return diagnosis(.unknown)
    }

    /// 由分类给出固定的原因与建议（不读取原始错误，避免泄露）
    public static func diagnosis(_ category: ErrorCategory) -> ErrorDiagnosis {
        switch category {
        case .missingAPIKey:
            return ErrorDiagnosis(
                category: category,
                cause: "还没有填写模型服务的 API Key。",
                suggestions: ["到「设置 → 模型」填写 API Key 后再试。"],
                isRetryable: false,
                needsUserAction: true
            )
        case .authentication:
            return ErrorDiagnosis(
                category: category,
                cause: "API Key 无效、已过期，或没有该模型的访问权限。",
                suggestions: ["检查 API Key 是否复制完整。", "确认账号已开通该模型。"],
                isRetryable: false,
                needsUserAction: true
            )
        case .rateLimited:
            return ErrorDiagnosis(
                category: category,
                cause: "短时间内请求过多，服务商正在限流。",
                suggestions: ["等几十秒后重试。", "降低同时进行的请求数。"],
                isRetryable: true,
                needsUserAction: false
            )
        case .quotaExceeded:
            return ErrorDiagnosis(
                category: category,
                cause: "服务商账户额度或余额不足。",
                suggestions: ["到服务商后台查看余额与用量。", "换用其他模型或服务商。"],
                isRetryable: false,
                needsUserAction: true
            )
        case .timeout:
            return ErrorDiagnosis(
                category: category,
                cause: "请求在限定时间内没有完成，通常是网络较慢或服务端繁忙。",
                suggestions: ["检查网络后重试。", "减少本轮上下文长度。"],
                isRetryable: true,
                needsUserAction: false
            )
        case .offline:
            return ErrorDiagnosis(
                category: category,
                cause: "当前没有可用网络连接。",
                suggestions: ["连接 Wi-Fi 或蜂窝网络后重试。", "本地已保存的聊天与记忆仍可查看。"],
                isRetryable: true,
                needsUserAction: false
            )
        case .modelNotFound:
            return ErrorDiagnosis(
                category: category,
                cause: "所选模型在当前服务商下不存在或已下线。",
                suggestions: ["到「设置 → 模型」重新获取模型列表并选择可用模型。"],
                isRetryable: false,
                needsUserAction: true
            )
        case .contextTooLong:
            return ErrorDiagnosis(
                category: category,
                cause: "本轮上下文超过了模型可接受的长度。",
                suggestions: ["新建会话再继续这个话题。", "减少引用的历史消息或附件。"],
                isRetryable: true,
                needsUserAction: false
            )
        case .invalidRequest:
            return ErrorDiagnosis(
                category: category,
                cause: "请求参数不被服务端接受。",
                suggestions: ["检查模型参数设置。", "换一个模型再试。"],
                isRetryable: false,
                needsUserAction: true
            )
        case .serverError:
            return ErrorDiagnosis(
                category: category,
                cause: "模型服务商暂时出现异常。",
                suggestions: ["稍后重试。", "如持续出现，换用其他服务商。"],
                isRetryable: true,
                needsUserAction: false
            )
        case .budgetExceeded:
            return ErrorDiagnosis(
                category: category,
                cause: "本次请求会超出你设置的预算上限，已被本地拦截。",
                suggestions: ["到「设置 → 预算与成本」调整上限。", "换用单价更低的模型。"],
                isRetryable: false,
                needsUserAction: true
            )
        case .databaseReadOnly:
            return ErrorDiagnosis(
                category: category,
                cause: "数据库处于只读状态，写入被拒绝以保护数据。",
                suggestions: ["在设置中查看完整性检查结果。", "必要时用备份恢复或重试升级。"],
                isRetryable: false,
                needsUserAction: true
            )
        case .storageFull:
            return ErrorDiagnosis(
                category: category,
                cause: "设备可用存储空间不足。",
                suggestions: ["清理附件库或旧备份。", "导出并删除不需要的会话。"],
                isRetryable: false,
                needsUserAction: true
            )
        case .backupCorrupted:
            return ErrorDiagnosis(
                category: category,
                cause: "备份文件校验未通过，可能已损坏或被截断。",
                suggestions: ["改用其他备份文件。", "重新创建一份备份。"],
                isRetryable: false,
                needsUserAction: true
            )
        case .migrationFailed:
            return ErrorDiagnosis(
                category: category,
                cause: "数据库升级没有完成，已回滚到升级前结构并暂停写入。",
                suggestions: ["在设置中重试升级。", "必要时从升级前备份恢复。"],
                isRetryable: true,
                needsUserAction: true
            )
        case .permissionDenied:
            return ErrorDiagnosis(
                category: category,
                cause: "系统或用户拒绝了本次操作所需的权限。",
                suggestions: ["到系统设置中开启对应权限。", "不使用该功能时可直接改用文字输入。"],
                isRetryable: false,
                needsUserAction: true
            )
        case .unknown:
            return ErrorDiagnosis(
                category: category,
                cause: "出现了未归类的错误。",
                suggestions: ["稍后重试。", "在「设置 → 关于与诊断」导出诊断信息以便排查。"],
                isRetryable: true,
                needsUserAction: false
            )
        }
    }
}

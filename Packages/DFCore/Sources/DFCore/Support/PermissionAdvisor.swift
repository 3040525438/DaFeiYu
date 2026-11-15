import Foundation

// MARK: - 权限管理（D69）
//
// 原则（硬规则）：
// - **不得提前申请**：启动与首页加载阶段一律不弹任何权限框；
// - 只在用户真正使用对应能力时（录音、语音转写、通知投递前）才申请；
// - 用户拒绝后不重复骚扰：给出替代方案与系统设置入口，由用户主动决定；
// - 受限（家长控制 / MDM）不引导反复申请，只说明不可用与替代方案。
//
// 全部为纯函数与值类型，不读系统状态、不弹窗，便于在 CI 上覆盖全部分支。

/// App 实际会用到、需要向系统申请的权限。
///
/// 刻意不包含相册：附件选择使用系统 PHPicker，本身不需要相册权限。
public enum AppPermission: String, Sendable, Equatable, CaseIterable {
    case notifications
    case microphone
    case speechRecognition = "speech_recognition"

    public var displayName: String {
        switch self {
        case .notifications: return "通知"
        case .microphone: return "麦克风"
        case .speechRecognition: return "语音识别"
        }
    }

    /// 为什么需要（展示给用户）
    public var purpose: String {
        switch self {
        case .notifications:
            return "主动关心、提醒与后台整理结果需要系统通知才能送达"
        case .microphone:
            return "按住说话录制语音消息时需要麦克风"
        case .speechRecognition:
            return "把语音转成文字需要使用系统语音识别"
        }
    }

    /// 被拒绝后的替代方案（不绕过系统，只告诉用户还能怎么用）
    public var alternative: String {
        switch self {
        case .notifications:
            return "不开通知也能正常聊天；主动消息只会在你打开 App 时显示"
        case .microphone:
            return "可以直接输入文字；语音输入不可用"
        case .speechRecognition:
            return "可以继续发语音，但不会自动转写；也可以改发文字"
        }
    }
}

/// 归一化后的权限状态（三方系统状态统一到同一套语义）
public enum PermissionStatus: String, Sendable, Equatable, CaseIterable {
    /// 尚未询问过
    case notDetermined = "not_determined"
    /// 已授权
    case granted
    /// 部分可用（如临时通知授权）
    case limited
    /// 用户明确拒绝
    case denied
    /// 系统限制（家长控制 / MDM），无法申请
    case restricted

    public var displayName: String {
        switch self {
        case .notDetermined: return "尚未询问"
        case .granted: return "已授权"
        case .limited: return "部分可用"
        case .denied: return "已拒绝"
        case .restricted: return "系统限制"
        }
    }

    /// 相关能力当前是否可用（部分可用按可用处理）
    public var isUsable: Bool { self == .granted || self == .limited }
}

/// 页面应该给出的下一步操作
public enum PermissionAction: String, Sendable, Equatable {
    /// 可以在用户点按时申请（仅 notDetermined）
    case request
    /// 只能引导用户去系统设置（已拒绝）
    case openSettings
    /// 无需操作（已授权 / 部分可用 / 系统限制）
    case none
}

/// 单个权限的完整建议
public struct PermissionAdvice: Sendable, Equatable {
    public var permission: AppPermission
    public var status: PermissionStatus
    public var action: PermissionAction
    /// 状态说明：一句话解释当前状态对功能的影响
    public var explanation: String

    public init(
        permission: AppPermission,
        status: PermissionStatus,
        action: PermissionAction,
        explanation: String
    ) {
        self.permission = permission
        self.status = status
        self.action = action
        self.explanation = explanation
    }

    public var purpose: String { permission.purpose }
    public var alternative: String { permission.alternative }
    public var isUsable: Bool { status.isUsable }
}

public enum PermissionAdvisor {
    /// 启动阶段是否申请任何权限。**永远为 false**（D69 硬规则）。
    public static let shouldRequestOnLaunch = false

    /// 是否应在"首次使用该能力"时申请：只有从未询问过才申请。
    public static func shouldRequestOnFirstUse(_ status: PermissionStatus) -> Bool {
        status == .notDetermined
    }

    /// 是否只能靠系统设置解决（已拒绝，App 内无法再次弹出授权框）。
    public static func requiresSystemSettings(_ status: PermissionStatus) -> Bool {
        status == .denied
    }

    /// 生成单个权限的建议。
    public static func advice(
        permission: AppPermission,
        status: PermissionStatus
    ) -> PermissionAdvice {
        let action: PermissionAction
        let explanation: String
        switch status {
        case .notDetermined:
            action = .request
            explanation = "尚未询问，会在你第一次使用时申请"
        case .granted:
            action = .none
            explanation = "已授权，功能可正常使用"
        case .limited:
            action = .none
            explanation = "仅有部分授权，功能可用但可能受限"
        case .denied:
            action = .openSettings
            explanation = "已被拒绝，需要到系统设置里手动开启"
        case .restricted:
            action = .none
            explanation = "系统限制（家长控制或设备管理），无法在 App 内申请"
        }
        return PermissionAdvice(
            permission: permission,
            status: status,
            action: action,
            explanation: explanation
        )
    }

    /// 批量生成建议，顺序固定为 `AppPermission.allCases`，缺失状态按"尚未询问"处理。
    public static func advices(_ statuses: [AppPermission: PermissionStatus]) -> [PermissionAdvice] {
        AppPermission.allCases.map { permission in
            advice(permission: permission, status: statuses[permission] ?? .notDetermined)
        }
    }
}

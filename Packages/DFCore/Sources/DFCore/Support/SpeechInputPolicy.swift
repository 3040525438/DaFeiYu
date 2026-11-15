import Foundation

// MARK: - 语音输入的运行方式与上传授权（D16）
//
// 目标：语音转写跟随当前运行方式；只要涉及上传，就必须先获得用户授权。
// 纯逻辑，不访问系统权限、不发请求，便于在 CI 覆盖全部分支。

/// 语音转写的运行方式
public enum SpeechRunMode: String, Sendable, Equatable, CaseIterable {
    /// 设备端识别（音频不出设备）
    case onDevice = "on_device"
    /// 云端识别（音频会离开设备）
    case cloud
    /// 当前不可用（设备不支持端上识别，且云端未配置/未授权）
    case unavailable

    public var displayName: String {
        switch self {
        case .onDevice: return "设备端"
        case .cloud: return "云端"
        case .unavailable: return "不可用"
        }
    }
}

/// 用户对"上传音频"的授权状态
public enum SpeechUploadConsent: String, Sendable, Equatable {
    case undetermined
    case granted
    case denied
}

/// 一次语音输入应当怎么处理
public struct SpeechInputPlan: Sendable, Equatable {
    public var mode: SpeechRunMode
    /// 是否涉及把音频上传出去
    public var requiresUploadConsent: Bool
    /// 当前是否允许开始转写
    public var allowed: Bool
    /// 状态说明（展示给用户）
    public var explanation: String
    /// 不可用时的替代方案
    public var alternative: String?

    public init(
        mode: SpeechRunMode,
        requiresUploadConsent: Bool,
        allowed: Bool,
        explanation: String,
        alternative: String?
    ) {
        self.mode = mode
        self.requiresUploadConsent = requiresUploadConsent
        self.allowed = allowed
        self.explanation = explanation
        self.alternative = alternative
    }
}

/// 语音输入相关设置键（App 层读写，策略层只做解析）
public enum SpeechSettingsKey {
    /// 运行方式：`on_device` / `cloud`
    public static let mode = "speech.mode"
    /// 云端转写使用的模型名（缺省为 `whisper-1`）
    public static let cloudModel = "speech.cloud_model"
}

extension SpeechRunMode {
    /// 从设置值解析运行方式。
    ///
    /// 未知值一律按设备端处理：不能因为一条脏设置就把音频悄悄推到云端。
    public init(settingValue: String?) {
        let raw = (settingValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch raw {
        case SpeechRunMode.cloud.rawValue: self = .cloud
        case SpeechRunMode.unavailable.rawValue: self = .unavailable
        default: self = .onDevice
        }
    }

    /// 可被用户选择的运行方式（"不可用"不是用户选项）
    public static var selectable: [SpeechRunMode] { [.onDevice, .cloud] }
}

public enum SpeechInputPolicy {
    /// 文字兜底：任何情况下都存在
    public static let textAlternative = "可以直接输入文字；语音输入只影响录入方式，不影响聊天"

    /// 计算本次语音输入的处理方式。
    ///
    /// - 设备端可用：直接允许，不需要上传授权；
    /// - 只剩云端：必须有显式授权，未授权一律不开始，并给出文字兜底；
    /// - 都不可用：明确不可用，绝不偷偷上传。
    public static func plan(
        preferred: SpeechRunMode,
        deviceOnDeviceAvailable: Bool,
        consent: SpeechUploadConsent
    ) -> SpeechInputPlan {
        if preferred == .onDevice {
            if deviceOnDeviceAvailable {
                return SpeechInputPlan(
                    mode: .onDevice,
                    requiresUploadConsent: false,
                    allowed: true,
                    explanation: "使用设备端识别，音频不会上传",
                    alternative: nil
                )
            }
            return SpeechInputPlan(
                mode: .unavailable,
                requiresUploadConsent: false,
                allowed: false,
                explanation: "当前设备不支持端上识别，且没有启用云端识别",
                alternative: textAlternative
            )
        }

        if preferred == .cloud {
            switch consent {
            case .granted:
                return SpeechInputPlan(
                    mode: .cloud,
                    requiresUploadConsent: true,
                    allowed: true,
                    explanation: "音频会上传到当前模型服务商进行识别，费用按服务商计费",
                    alternative: nil
                )
            case .undetermined:
                return SpeechInputPlan(
                    mode: .cloud,
                    requiresUploadConsent: true,
                    allowed: false,
                    explanation: "云端识别需要你明确授权上传音频",
                    alternative: textAlternative
                )
            case .denied:
                return SpeechInputPlan(
                    mode: .cloud,
                    requiresUploadConsent: true,
                    allowed: false,
                    explanation: "你已拒绝上传音频，云端识别不会启动",
                    alternative: textAlternative
                )
            }
        }

        return SpeechInputPlan(
            mode: .unavailable,
            requiresUploadConsent: false,
            allowed: false,
            explanation: "当前没有可用的语音识别方式",
            alternative: textAlternative
        )
    }

    /// 是否需要在开始录音前弹出授权说明。
    public static func needsConsentPrompt(_ plan: SpeechInputPlan) -> Bool {
        plan.requiresUploadConsent && !plan.allowed
    }
}

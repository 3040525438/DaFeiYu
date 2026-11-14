import Foundation

// MARK: - 隐私门禁与数据删除（W9 / D45、D59、D63）

public enum PrivacyLockReason: String, Codable, Sendable, Equatable {
    case launch
    case foreground
    case manual
    case sensitiveAction

    public var description: String {
        switch self {
        case .launch: return "App 启动需要解锁"
        case .foreground: return "回到前台需要解锁"
        case .manual: return "已手动锁定"
        case .sensitiveAction: return "敏感操作需要解锁"
        }
    }
}

public struct PrivacySettings: Codable, Sendable, Equatable {
    public var lockEnabled: Bool
    public var biometricsEnabled: Bool
    /// 只存哈希，永不存明文
    public var passcodeHash: String?
    /// 进入后台多少秒后回前台需要解锁（0 = 立即）
    public var lockDelaySeconds: Int
    public var maxFailedAttempts: Int
    public var lockoutSeconds: Int
    /// 多任务切换器里隐藏内容
    public var hideContentInSwitcher: Bool

    public init(
        lockEnabled: Bool = false,
        biometricsEnabled: Bool = false,
        passcodeHash: String? = nil,
        lockDelaySeconds: Int = 0,
        maxFailedAttempts: Int = 5,
        lockoutSeconds: Int = 60,
        hideContentInSwitcher: Bool = true
    ) {
        self.lockEnabled = lockEnabled
        self.biometricsEnabled = biometricsEnabled
        self.passcodeHash = passcodeHash
        self.lockDelaySeconds = lockDelaySeconds
        self.maxFailedAttempts = maxFailedAttempts
        self.lockoutSeconds = lockoutSeconds
        self.hideContentInSwitcher = hideContentInSwitcher
    }

    public static let `default` = PrivacySettings()
}

public struct PrivacyGateState: Codable, Sendable, Equatable {
    public var isLocked: Bool
    public var failedAttempts: Int
    public var lockedUntil: Int64?
    public var lastEnteredBackgroundAt: Int64?
    public var lastUnlockedAt: Int64?

    public init(
        isLocked: Bool = false,
        failedAttempts: Int = 0,
        lockedUntil: Int64? = nil,
        lastEnteredBackgroundAt: Int64? = nil,
        lastUnlockedAt: Int64? = nil
    ) {
        self.isLocked = isLocked
        self.failedAttempts = failedAttempts
        self.lockedUntil = lockedUntil
        self.lastEnteredBackgroundAt = lastEnteredBackgroundAt
        self.lastUnlockedAt = lastUnlockedAt
    }

    public static let initial = PrivacyGateState()
}

public enum PrivacyGateEvent: Sendable, Equatable {
    case appLaunch
    case enterBackground
    case foreground
    case unlockAttempt
    case sensitiveAction
}

public enum PrivacyGateDecision: Sendable, Equatable {
    case allowed
    case requiresUnlock(PrivacyLockReason)
    case lockedOut(until: Int64)
}

public enum PrivacyGate {
    /// 本地口令哈希盐（每个安装实例的口令只用于本地校验）
    public static let passcodeSalt = "dafeiyu.local.privacy.v1"

    public static func hashPasscode(_ code: String) -> String {
        SHA256.hash(passcodeSalt + "|" + code)
    }

    public static func verify(passcode: String, settings: PrivacySettings) -> Bool {
        guard let stored = settings.passcodeHash, !stored.isEmpty else { return false }
        return hashPasscode(passcode) == stored
    }

    public static func decision(
        settings: PrivacySettings,
        state: PrivacyGateState,
        event: PrivacyGateEvent,
        reason: PrivacyLockReason = .sensitiveAction,
        at millis: Int64
    ) -> PrivacyGateDecision {
        if let until = state.lockedUntil, millis < until {
            return .lockedOut(until: until)
        }
        guard settings.lockEnabled else { return .allowed }
        switch event {
        case .appLaunch:
            return state.isLocked ? .requiresUnlock(.launch) : .allowed
        case .enterBackground:
            return .allowed
        case .foreground:
            return shouldLockOnForeground(settings: settings, state: state, at: millis)
                ? .requiresUnlock(.foreground)
                : .allowed
        case .unlockAttempt, .sensitiveAction:
            return state.isLocked ? .requiresUnlock(reason) : .allowed
        }
    }

    public static func shouldLockOnForeground(
        settings: PrivacySettings,
        state: PrivacyGateState,
        at millis: Int64
    ) -> Bool {
        guard settings.lockEnabled else { return false }
        if state.isLocked { return true }
        guard let backgroundAt = state.lastEnteredBackgroundAt else { return false }
        return millis - backgroundAt >= Int64(max(settings.lockDelaySeconds, 0)) * 1000
    }

    public static func enterBackground(_ state: PrivacyGateState, at millis: Int64) -> PrivacyGateState {
        var next = state
        next.lastEnteredBackgroundAt = millis
        return next
    }

    public static func lock(_ state: PrivacyGateState) -> PrivacyGateState {
        var next = state
        next.isLocked = true
        return next
    }

    public static func registerSuccess(_ state: PrivacyGateState, at millis: Int64) -> PrivacyGateState {
        var next = state
        next.isLocked = false
        next.failedAttempts = 0
        next.lockedUntil = nil
        next.lastUnlockedAt = millis
        return next
    }

    /// 失败计数到上限后进入锁定窗口；窗口内连正确口令也不放行。
    public static func registerFailure(
        _ state: PrivacyGateState,
        settings: PrivacySettings,
        at millis: Int64
    ) -> PrivacyGateState {
        var next = state
        next.isLocked = true
        next.failedAttempts += 1
        if next.failedAttempts >= max(settings.maxFailedAttempts, 1) {
            next.lockedUntil = millis + Int64(max(settings.lockoutSeconds, 0)) * 1000
            next.failedAttempts = 0
        }
        return next
    }
}

// MARK: - 隐私授权记录（D59）

public enum PrivacyConsentKind: String, Codable, Sendable, CaseIterable {
    case cloudModel = "cloud_model"
    case externalBackup = "external_backup"
    case diagnosticsExport = "diagnostics_export"
    case importExport = "import_export"
    case speechRecognition = "speech_recognition"
    case photoAccess = "photo_access"

    public var title: String {
        switch self {
        case .cloudModel: return "云端模型"
        case .externalBackup: return "导出到外部位置"
        case .diagnosticsExport: return "导出诊断信息"
        case .importExport: return "导入/导出数据"
        case .speechRecognition: return "语音转写"
        case .photoAccess: return "访问照片"
        }
    }

    public var detail: String {
        switch self {
        case .cloudModel: return "使用云端模型时，本轮文本会发送到所配置的服务商"
        case .externalBackup: return "备份文件会写到 App 沙盒之外，需自行保护"
        case .diagnosticsExport: return "诊断包只包含脱敏后的运行信息"
        case .importExport: return "读取外部导入包会读取你选择目录中的文件"
        case .speechRecognition: return "转写优先在设备端完成；无法完成时才考虑云端"
        case .photoAccess: return "只读取你主动选择的照片"
        }
    }
}

public struct PrivacyConsent: Codable, Sendable, Equatable {
    public var kind: PrivacyConsentKind
    public var granted: Bool
    public var updatedAt: Int64
    public var note: String

    public init(kind: PrivacyConsentKind, granted: Bool, updatedAt: Int64, note: String = "") {
        self.kind = kind
        self.granted = granted
        self.updatedAt = updatedAt
        self.note = note
    }
}

// MARK: - 数据删除清单（D45）

public struct DataDeletionItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    public var count: Int

    public init(id: String, title: String, detail: String, count: Int) {
        self.id = id
        self.title = title
        self.detail = detail
        self.count = count
    }
}

public struct DataDeletionPlan: Codable, Sendable, Equatable {
    /// 必须逐字输入该短语才允许执行
    public static let confirmationPhrase = "彻底删除全部数据"

    public var items: [DataDeletionItem]
    public var totalCount: Int
    public var keyLossWarning: String

    public init(items: [DataDeletionItem], totalCount: Int, keyLossWarning: String) {
        self.items = items
        self.totalCount = totalCount
        self.keyLossWarning = keyLossWarning
    }

    public static let keyLossWarningText = "删除后本地加密密钥会一并销毁：已有备份文件将无法再解密，且不可恢复。"
}

import Foundation

// MARK: - 跨设备恢复判定（D72）
//
// 需求：多设备可用备份恢复；恢复前必须有保护备份；是否替换由用户决定；不自动合并。
//
// 这里只做判定，不写库、不做 IO：
// - 本机备份、版本兼容 → 允许直接进入恢复流程（仍会先做保护备份）；
// - 其他设备或来源未知 → 必须用户明确确认，且提示"整体替换，不合并"；
// - 备份 schema 比当前 App 新 → 拒绝（降级恢复会让旧结构写坏新数据）。

public enum RestoreOrigin: String, Sendable, Equatable, CaseIterable {
    /// 同一台设备
    case sameDevice
    /// 其他设备
    case otherDevice
    /// 备份未记录设备（历史备份）
    case unknown

    public var displayName: String {
        switch self {
        case .sameDevice: return "本机备份"
        case .otherDevice: return "其他设备的备份"
        case .unknown: return "来源未知的备份"
        }
    }
}

/// 恢复判定的输入事实
public struct RestoreFacts: Sendable, Equatable {
    public var backupDeviceID: String?
    public var currentDeviceID: String?
    public var backupSchemaVersion: String
    public var currentSchemaVersion: String
    public var isSpaceOK: Bool
    /// 是否已有恢复前保护备份（D42/D72 要求）
    public var hasSafetyBackup: Bool

    public init(
        backupDeviceID: String?,
        currentDeviceID: String?,
        backupSchemaVersion: String,
        currentSchemaVersion: String,
        isSpaceOK: Bool,
        hasSafetyBackup: Bool
    ) {
        self.backupDeviceID = backupDeviceID
        self.currentDeviceID = currentDeviceID
        self.backupSchemaVersion = backupSchemaVersion
        self.currentSchemaVersion = currentSchemaVersion
        self.isSpaceOK = isSpaceOK
        self.hasSafetyBackup = hasSafetyBackup
    }
}

public enum RestoreDecision: Sendable, Equatable {
    /// 可以直接恢复（保护备份已存在且版本兼容）
    case allowed
    /// 必须用户明确确认后才可恢复
    case requiresConfirmation(reason: String)
    /// 拒绝恢复
    case blocked(reason: String)

    public var canProceedWithoutPrompt: Bool {
        if case .allowed = self { return true }
        return false
    }

    public var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }

    public var message: String? {
        switch self {
        case .allowed: return nil
        case .requiresConfirmation(let reason), .blocked(let reason): return reason
        }
    }
}

public enum RestoreOriginPolicy {
    /// 判定备份来源
    public static func origin(backupDeviceID: String?, currentDeviceID: String?) -> RestoreOrigin {
        guard let backup = normalized(backupDeviceID) else { return .unknown }
        guard let current = normalized(currentDeviceID) else { return .unknown }
        return backup == current ? .sameDevice : .otherDevice
    }

    /// 版本比较：只有 `a` 不旧于 `b` 才返回 true；无法解析时按"不可比"处理（保守拒绝）
    public static func isVersion(_ a: String, atLeast b: String) -> Bool {
        compareVersions(a, b) >= 0
    }

    /// 完整判定
    public static func decision(origin: RestoreOrigin, facts: RestoreFacts) -> RestoreDecision {
        guard isVersion(facts.currentSchemaVersion, atLeast: facts.backupSchemaVersion) else {
            return .blocked(
                reason: "该备份由更新的 App 创建（结构版本 \(facts.backupSchemaVersion) 高于当前 \(facts.currentSchemaVersion)），请先升级 App 再恢复。"
            )
        }
        guard facts.isSpaceOK else {
            return .blocked(reason: "可用存储空间不足，请清理后再恢复。")
        }
        guard facts.hasSafetyBackup else {
            return .blocked(reason: "恢复前必须先创建一份保护备份，本次恢复已中止。")
        }
        switch origin {
        case .sameDevice:
            return .allowed
        case .otherDevice:
            return .requiresConfirmation(
                reason: "这是其他设备的备份。恢复会用备份内容整体替换本机聊天、记忆、日记与人格档案，不会自动合并；本机现有数据会先做一份保护备份。"
            )
        case .unknown:
            return .requiresConfirmation(
                reason: "该备份未记录来源设备。恢复会用备份内容整体替换本机数据，不会自动合并；本机现有数据会先做一份保护备份。"
            )
        }
    }

    /// 便捷入口：直接从事实推导来源再判定
    public static func decision(facts: RestoreFacts) -> RestoreDecision {
        decision(
            origin: origin(backupDeviceID: facts.backupDeviceID, currentDeviceID: facts.currentDeviceID),
            facts: facts
        )
    }

    // MARK: - 内部

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// 语义化版本比较：按数字段比较，非数字段按字符串比较；
    /// 段数不同时短的一方补 0（"v14" 与 "v14_message_organization" 视为不旧于后者？否——补 0 后 v14 < v14_message）
    static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let left = segments(lhs)
        let right = segments(rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : "0"
            let b = index < right.count ? right[index] : "0"
            if a == b { continue }
            if let na = Int(a), let nb = Int(b) {
                return na < nb ? -1 : 1
            }
            return a < b ? -1 : 1
        }
        return 0
    }

    /// 拆分版本号：先按 `_` `.` `-` ` ` 切，再把连续数字/字母分开。
    /// 空值、`none`、`unknown` 视为最旧（全新安装必须能恢复备份）。
    private static func segments(_ value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed != "none", trimmed != "unknown" else { return ["0"] }
        return trimmed
            .split(whereSeparator: { $0 == "_" || $0 == "." || $0 == "-" || $0 == " " })
            .flatMap { chunk -> [String] in
                var result: [String] = []
                var buffer = ""
                var lastIsDigit: Bool?
                for character in chunk {
                    let isDigit = character.isNumber
                    if let last = lastIsDigit, last != isDigit, !buffer.isEmpty {
                        result.append(buffer)
                        buffer = ""
                    }
                    buffer.append(character)
                    lastIsDigit = isDigit
                }
                if !buffer.isEmpty { result.append(buffer) }
                return result
            }
    }
}

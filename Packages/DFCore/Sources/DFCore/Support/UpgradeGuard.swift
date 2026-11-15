import Foundation

// MARK: - 升级保护（D67）
//
// 目标：升级前先判断是否允许升级、是否需要备份，升级过程留痕，失败可追溯。
// 这里只做**纯判断**，不读数据库、不写文件，便于在 CI 覆盖新旧版本组合。

/// 升级计划
public enum UpgradePlan: Sendable, Equatable {
    /// 全新安装（没有历史版本）
    case freshInstall
    /// 需要从 `from` 升到 `to`
    case upgrade(from: String, to: String)
    /// 已是最新版本
    case upToDate(version: String)
    /// 拒绝升级（未知版本 / 降级）
    case blocked(reason: String)
}

/// 升级记录状态机
public enum UpgradeAuditStatus: String, Sendable, Equatable, CaseIterable {
    case running
    case succeeded
    case failed
    /// 升级失败后从备份回退成功
    case rolledBack = "rolled_back"

    public var displayName: String {
        switch self {
        case .running: return "进行中"
        case .succeeded: return "已成功"
        case .failed: return "已失败"
        case .rolledBack: return "已回退"
        }
    }
}

public enum UpgradeGuard {
    /// 未知版本标记（全新库 / 读不到 schema_meta）
    public static let unknownVersion = "none"

    /// 计算升级计划。
    ///
    /// - `currentVersion` 为空 / `none` → 全新安装；
    /// - 不在已知迁移链内 → 拒绝（不猜测结构）；
    /// - 库里版本比当前 App 新（索引更靠后）→ 拒绝，防止旧 App 写坏新库；
    /// - 相等 → 无需升级。
    public static func plan(
        currentVersion: String?,
        knownVersions: [String],
        latestVersion: String
    ) -> UpgradePlan {
        let current = (currentVersion ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty, current != unknownVersion else { return .freshInstall }
        guard let latestIndex = knownVersions.firstIndex(of: latestVersion) else {
            return .blocked(reason: "当前 App 的目标版本不在迁移链内：\(latestVersion)")
        }
        guard let currentIndex = knownVersions.firstIndex(of: current) else {
            return .blocked(reason: "数据库版本不在已知迁移链内，拒绝自动升级：\(current)")
        }
        if currentIndex > latestIndex {
            return .blocked(reason: "数据库版本（\(current)）比当前 App（\(latestVersion)）更新，请升级 App")
        }
        if currentIndex == latestIndex {
            return .upToDate(version: current)
        }
        return .upgrade(from: current, to: latestVersion)
    }

    /// 升级前是否必须先备份。只有真正需要迁移时才要求备份。
    public static func requiresPreUpgradeBackup(_ plan: UpgradePlan) -> Bool {
        if case .upgrade = plan { return true }
        return false
    }

    /// 是否允许在启动时自动迁移（被拒绝的计划一律不迁移）。
    public static func shouldMigrate(_ plan: UpgradePlan) -> Bool {
        switch plan {
        case .freshInstall, .upgrade: return true
        case .upToDate, .blocked: return false
        }
    }

    /// 升级记录状态迁移是否合法。
    ///
    /// 只允许：running → succeeded / failed；failed → rolledBack。
    /// 已成功或已回退的记录不得再改状态。
    public static func canTransition(from: UpgradeAuditStatus, to: UpgradeAuditStatus) -> Bool {
        switch (from, to) {
        case (.running, .succeeded), (.running, .failed), (.failed, .rolledBack):
            return true
        default:
            return false
        }
    }
}

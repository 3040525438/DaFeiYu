import Foundation

// MARK: - 升级前备份策略（D67）
//
// 只做纯判断：是否需要备份、备份目录如何命名、旧备份保留多少、哪些该清理。
// 真实的文件复制由 DFData 的 `PreUpgradeBackupService` 完成。

public enum PreUpgradeBackupPolicy {
    /// 备份根目录名（位于数据库根目录下）
    public static let directoryRootName = "PreUpgradeBackups"
    /// 默认保留最近 5 份升级前备份
    public static let defaultRetention = 5
    /// 版本号在文件名中的最大长度
    public static let maxVersionLength = 40

    /// 是否需要升级前备份：只有真正要迁移时才备份（全新安装、已最新、被拒绝都不备份）。
    public static func shouldBackup(_ plan: UpgradePlan) -> Bool {
        UpgradeGuard.requiresPreUpgradeBackup(plan)
    }

    /// 备份目录名：`<毫秒时间戳>-<安全化版本>`。
    /// 时间戳在可预见范围内是定长 13 位，因此按名字排序等价于按时间排序。
    public static func directoryName(timestamp: Int64, version: String) -> String {
        let safe = sanitized(version)
        return "\(timestamp)-\(safe)"
    }

    /// 把版本号转成文件名安全片段：只保留字母/数字/下划线/连字符，超长截断，空则 `unknown`。
    public static func sanitized(_ version: String) -> String {
        let mapped = version.map { character -> Character in
            if character.isLetter || character.isNumber || character == "_" || character == "-" {
                return character
            }
            return "_"
        }
        let trimmed = String(mapped.prefix(maxVersionLength))
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    /// 计算需要删除的旧备份目录名。
    ///
    /// - 按名字中的时间戳升序排列；
    /// - 保留最后 `keeping` 份，并且**永远保留本次新建的 `current`**；
    /// - `keeping <= 0` 表示只保留本次新建的那一份。
    public static func expiredDirectoryNames(
        existing: [String],
        keeping: Int,
        current: String
    ) -> [String] {
        let ordered = existing.sorted { lhs, rhs in
            let left = timestampPrefix(lhs)
            let right = timestampPrefix(rhs)
            if left != right { return left < right }
            return lhs < rhs
        }
        let keepCount = max(0, keeping)
        var keep = Set(ordered.suffix(keepCount))
        keep.insert(current)
        return ordered.filter { !keep.contains($0) }
    }

    /// 取名字前缀的毫秒时间戳；不是数字开头时返回 0（排序时排在最前，优先被清理）
    public static func timestampPrefix(_ name: String) -> Int64 {
        let digits = name.prefix { $0.isNumber }
        return Int64(digits) ?? 0
    }
}

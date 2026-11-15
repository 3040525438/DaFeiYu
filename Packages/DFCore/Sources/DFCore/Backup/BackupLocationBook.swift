import Foundation

// MARK: - 外部备份位置清单（D41）
//
// 只做纯数据：位置清单的编解码、去重、上限与多位置复制结果文案。
// 安全作用域书签的读写留在 App 层（依赖系统 API），这里保证规则可测、可回放。

/// 一个已授权的外部备份位置
public struct BackupLocation: Sendable, Equatable, Identifiable, Codable {
    public var id: String
    public var name: String
    /// 安全作用域书签的 base64；只在 App 层解析
    public var bookmarkBase64: String

    public init(id: String = UUID().uuidString, name: String, bookmarkBase64: String) {
        self.id = id
        self.name = name
        self.bookmarkBase64 = bookmarkBase64
    }
}

public enum BackupLocationBook {
    /// 同时维护的外部位置上限：再多就超出用户能维护的范围
    public static let maxCount = 5

    /// 解析清单。脏数据一律视为空，不让一条坏记录挡住整个备份页。
    public static func decode(_ json: String?) -> [BackupLocation] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        guard let decoded = try? JSONDecoder().decode([BackupLocation].self, from: data) else { return [] }
        return decoded.filter { !$0.id.isEmpty && !$0.name.isEmpty && !$0.bookmarkBase64.isEmpty }
    }

    public static func encode(_ locations: [BackupLocation]) -> String {
        guard let data = try? JSONEncoder().encode(locations),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    /// 加入一个位置。
    ///
    /// 同一个目录可能被重复授权：按 id、名称、书签任一相同即视为同一位置，覆盖后移到末尾。
    /// 超过上限时丢弃最早的一个，保证"最新的授权一定保留"。
    public static func upserting(
        _ location: BackupLocation,
        into existing: [BackupLocation],
        maxCount: Int = maxCount
    ) -> [BackupLocation] {
        var result = existing.filter {
            $0.id != location.id
                && $0.name != location.name
                && $0.bookmarkBase64 != location.bookmarkBase64
        }
        result.append(location)
        let limit = max(1, maxCount)
        if result.count > limit {
            result = Array(result.suffix(limit))
        }
        return result
    }

    public static func removing(id: String, from existing: [BackupLocation]) -> [BackupLocation] {
        existing.filter { $0.id != id }
    }

    public static func isFull(_ locations: [BackupLocation], maxCount: Int = maxCount) -> Bool {
        locations.count >= max(1, maxCount)
    }

    /// 旧版单目录设置迁移为清单（清单为空时使用）。
    public static func migrating(legacyBookmark: String?, legacyName: String?) -> [BackupLocation] {
        guard let bookmark = legacyBookmark?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bookmark.isEmpty else { return [] }
        let name = legacyName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return [BackupLocation(name: name.isEmpty ? "外部目录" : name, bookmarkBase64: bookmark)]
    }
}

/// 单个外部位置的复制结果
public struct BackupMirrorResult: Sendable, Equatable {
    public var locationID: String
    public var locationName: String
    public var succeeded: Bool
    public var detail: String

    public init(locationID: String, locationName: String, succeeded: Bool, detail: String) {
        self.locationID = locationID
        self.locationName = locationName
        self.succeeded = succeeded
        self.detail = detail
    }
}

public enum BackupMirrorSummary {
    /// 多位置复制的统一文案：单个失败不影响其他位置，也不谎报成功。
    public static func text(for results: [BackupMirrorResult]) -> String {
        guard !results.isEmpty else { return "还没有可用的外部位置" }

        let succeeded = results.filter(\.succeeded)
        let failed = results.filter { !$0.succeeded }

        if failed.isEmpty {
            return "已复制到 \(succeeded.count) 个外部位置："
                + succeeded.map(\.locationName).joined(separator: "、")
        }
        if succeeded.isEmpty {
            return "全部失败：" + failed.map { "\($0.locationName)（\($0.detail)）" }.joined(separator: "；")
        }
        return "成功 \(succeeded.count) / 共 \(results.count)："
            + "失败 " + failed.map { "\($0.locationName)（\($0.detail)）" }.joined(separator: "；")
    }
}

import Foundation
import DFCore
import DFData

/// 外部备份位置（D41）。
///
/// 说明：这里走系统文件选择器拿到的**安全作用域目录**（iCloud Drive、第三方网盘在
/// 「文件」里的提供器都可选），不内置厂商 OAuth SDK；因此"授权"范围由系统文件权限控制。
/// 选中目录后保存安全作用域书签，之后复制备份时重新解析授权。
///
/// 多位置：清单与去重/上限规则在 `BackupLocationBook`（纯逻辑，CI 覆盖），
/// 本文件只负责书签读写与系统授权。
enum ExternalBackupLocation {
    static let keyLocations = "backup.external.locations"
    /// 旧版单目录设置（只作为迁移来源，迁移后清空）
    static let keyBookmark = "backup.external.bookmark"
    static let keyName = "backup.external.name"

    enum Error: Swift.Error, CustomStringConvertible {
        case notConfigured
        case permissionDenied
        case bookmarkInvalid
        case tooManyLocations(limit: Int)
        case sizeMismatch(expected: Int64, actual: Int64)

        var description: String {
            switch self {
            case .notConfigured: return "还没有选择外部备份目录"
            case .permissionDenied: return "外部目录授权已失效，请重新选择"
            case .bookmarkInvalid: return "外部目录书签无法解析，请重新选择"
            case .tooManyLocations(let limit): return "最多同时维护 \(limit) 个外部位置，请先移除一个"
            case .sizeMismatch(let expected, let actual):
                return "复制后的文件大小不一致（期望 \(expected) 字节，实际 \(actual) 字节）"
            }
        }
    }

    /// 读取位置清单；清单为空时尝试把旧版单目录迁移进来（只迁移一次）。
    static func load(settings: SettingsRepository) async -> [BackupLocation] {
        let json = try? await settings.string(for: keyLocations)
        let decoded = BackupLocationBook.decode(json)
        if !decoded.isEmpty { return decoded }

        let legacyBookmark = try? await settings.string(for: keyBookmark)
        let legacyName = try? await settings.string(for: keyName)
        let migrated = BackupLocationBook.migrating(legacyBookmark: legacyBookmark, legacyName: legacyName)
        guard !migrated.isEmpty else { return [] }

        try? await settings.set(BackupLocationBook.encode(migrated), for: keyLocations)
        try? await settings.set("", for: keyBookmark)
        try? await settings.set("", for: keyName)
        return migrated
    }

    /// 新增（或覆盖）一个位置，返回最新清单。
    @discardableResult
    static func add(url: URL, settings: SettingsRepository) async throws -> [BackupLocation] {
        let existing = await load(settings: settings)
        guard !BackupLocationBook.isFull(existing) else {
            throw Error.tooManyLocations(limit: BackupLocationBook.maxCount)
        }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let location = BackupLocation(
            name: url.lastPathComponent,
            bookmarkBase64: bookmark.base64EncodedString()
        )
        let updated = BackupLocationBook.upserting(location, into: existing)
        try await settings.set(BackupLocationBook.encode(updated), for: keyLocations)
        return updated
    }

    @discardableResult
    static func remove(id: String, settings: SettingsRepository) async throws -> [BackupLocation] {
        let updated = BackupLocationBook.removing(id: id, from: await load(settings: settings))
        try await settings.set(BackupLocationBook.encode(updated), for: keyLocations)
        return updated
    }

    static func clearAll(settings: SettingsRepository) async throws {
        try await settings.set("[]", for: keyLocations)
        try await settings.set("", for: keyBookmark)
        try await settings.set("", for: keyName)
    }

    /// 解析书签并开始访问；调用方负责 stopAccessing
    static func resolve(_ location: BackupLocation) throws -> URL {
        guard let data = Data(base64Encoded: location.bookmarkBase64) else {
            throw Error.bookmarkInvalid
        }
        var stale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } catch {
            throw Error.bookmarkInvalid
        }
        guard url.startAccessingSecurityScopedResource() else {
            throw Error.permissionDenied
        }
        return url
    }
}

/// 把已生成的加密备份复制到外部位置（D41）。
///
/// 只做文件级复制与大小校验，不重新打包、不改动本地清单；
/// 多个位置互相独立：一个失败不影响其他位置，也不会把失败记成成功。
struct BackupMirrorService {
    let settings: SettingsRepository
    let backupService: BackupService

    func locations() async -> [BackupLocation] {
        await ExternalBackupLocation.load(settings: settings)
    }

    /// 复制到全部已授权位置，按位置逐个返回结果
    func copyToAll(_ manifest: BackupManifest) async -> [BackupMirrorResult] {
        let places = await locations()
        var results: [BackupMirrorResult] = []
        for place in places {
            do {
                _ = try copy(manifest, to: place)
                results.append(
                    BackupMirrorResult(
                        locationID: place.id,
                        locationName: place.name,
                        succeeded: true,
                        detail: ""
                    )
                )
            } catch {
                results.append(
                    BackupMirrorResult(
                        locationID: place.id,
                        locationName: place.name,
                        succeeded: false,
                        detail: describe(error)
                    )
                )
            }
        }
        return results
    }

    /// 复制到单个位置，返回目标路径
    func copy(_ manifest: BackupManifest, to location: BackupLocation) throws -> URL {
        let directory = try ExternalBackupLocation.resolve(location)
        defer { directory.stopAccessingSecurityScopedResource() }

        let source = backupService.fileURL(for: manifest)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ExternalBackupLocation.Error.bookmarkInvalid
        }
        let target = directory.appendingPathComponent(manifest.fileName)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: source, to: target)

        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size == manifest.byteSize else {
            throw ExternalBackupLocation.Error.sizeMismatch(
                expected: manifest.byteSize,
                actual: size
            )
        }
        return target
    }

    private func describe(_ error: Error) -> String {
        if let customized = error as? CustomStringConvertible {
            return customized.description
        }
        return error.localizedDescription
    }
}

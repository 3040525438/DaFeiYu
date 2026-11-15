import Foundation
import DFCore
import DFData

/// 外部备份位置（D41）。
///
/// 说明：这里走系统文件选择器拿到的**安全作用域目录**（iCloud Drive、第三方网盘在
/// 「文件」里的提供器都可选），不内置厂商 OAuth SDK；因此"授权"范围由系统文件权限控制。
/// 选中目录后保存安全作用域书签，之后复制备份时重新解析授权。
enum ExternalBackupLocation {
    static let keyBookmark = "backup.external.bookmark"
    static let keyName = "backup.external.name"

    enum Error: Swift.Error, CustomStringConvertible {
        case notConfigured
        case permissionDenied
        case bookmarkInvalid
        case sizeMismatch(expected: Int64, actual: Int64)

        var description: String {
            switch self {
            case .notConfigured: return "还没有选择外部备份目录"
            case .permissionDenied: return "外部目录授权已失效，请重新选择"
            case .bookmarkInvalid: return "外部目录书签无法解析，请重新选择"
            case .sizeMismatch(let expected, let actual):
                return "复制后的文件大小不一致（期望 \(expected) 字节，实际 \(actual) 字节）"
            }
        }
    }

    /// 把系统文件选择器返回的目录保存为书签
    static func save(url: URL, settings: SettingsRepository) async throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try await settings.set(bookmark.base64EncodedString(), for: keyBookmark)
        try await settings.set(url.lastPathComponent, for: keyName)
    }

    static func clear(settings: SettingsRepository) async throws {
        try await settings.set("", for: keyBookmark)
        try await settings.set("", for: keyName)
    }

    static func displayName(settings: SettingsRepository) async -> String? {
        guard let name = try? await settings.string(for: keyName), !name.isEmpty else {
            return nil
        }
        return name
    }

    /// 解析书签并开始访问；调用方负责 stopAccessing
    static func resolve(settings: SettingsRepository) async throws -> URL {
        guard let encoded = try await settings.string(for: keyBookmark),
              !encoded.isEmpty,
              let data = Data(base64Encoded: encoded) else {
            throw Error.notConfigured
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

/// 把已生成的加密备份复制到外部目录（D41）。
///
/// 只做文件级复制与大小校验，不重新打包、不改动本地清单。
struct BackupMirrorService {
    let settings: SettingsRepository
    let backupService: BackupService

    func isConfigured() async -> Bool {
        await ExternalBackupLocation.displayName(settings: settings) != nil
    }

    /// 返回外部目录中的目标路径
    func copy(_ manifest: BackupManifest) async throws -> URL {
        let directory = try await ExternalBackupLocation.resolve(settings: settings)
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
}

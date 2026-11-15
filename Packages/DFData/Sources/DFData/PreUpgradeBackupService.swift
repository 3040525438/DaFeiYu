import Foundation
import DFCore

/// 一次升级前备份的结果（D67）。
public struct PreUpgradeBackupResult: Sendable, Equatable {
    /// 备份目录名（即备份 id，可直接写进 `upgrade_records.pre_upgrade_backup_id`）
    public let id: String
    public let directory: URL
    public let fromVersion: String
    /// 已复制的文件名（主库 / -wal / -shm / manifest.json）
    public let files: [String]
    public let totalBytes: Int64
    /// 本次清理掉的旧备份目录名
    public let removed: [String]
}

public enum PreUpgradeBackupError: Error, Equatable, CustomStringConvertible {
    case databaseMissing(String)
    case copyFailed(file: String, reason: String)

    public var description: String {
        switch self {
        case .databaseMissing(let name):
            return "升级前备份失败：数据库文件不存在（\(name)）"
        case .copyFailed(let file, let reason):
            return "升级前备份失败：复制 \(file) 出错（\(reason)）"
        }
    }
}

/// 升级前把数据库文件（含 WAL/SHM）原样复制一份，供升级失败时回退（D67）。
///
/// 边界：
/// - 只读源文件、只写 `PreUpgradeBackups/` 目录，不碰业务表；
/// - 不改变源库，不支持"从备份恢复"（恢复走备份体系）；
/// - 保留最近 N 份，超出部分按时间从旧到新删除；
/// - 备份失败抛错，由调用方决定是否继续升级（不在这里静默吞掉）。
public final class PreUpgradeBackupService: @unchecked Sendable {
    private let paths: DatabasePaths
    private let fileManager: FileManager
    private let retention: Int
    private let now: @Sendable () -> Int64

    public init(
        paths: DatabasePaths,
        retention: Int = PreUpgradeBackupPolicy.defaultRetention,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Int64 = { Clock.nowMillis() }
    ) {
        self.paths = paths
        self.retention = retention
        self.fileManager = fileManager
        self.now = now
    }

    /// 备份根目录
    public var backupsRoot: URL {
        paths.root.appendingPathComponent(PreUpgradeBackupPolicy.directoryRootName, isDirectory: true)
    }

    /// 已存在的备份目录名（不保证顺序）
    public func existingBackupIDs() -> [String] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: backupsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.compactMap { url in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDirectory ? url.lastPathComponent : nil
        }
    }

    /// 执行一次升级前备份。
    /// - Parameter fromVersion: 升级前的数据库版本（写入目录名与清单）
    @discardableResult
    public func backup(fromVersion: String) throws -> PreUpgradeBackupResult {
        let source = paths.databaseURL
        guard fileManager.fileExists(atPath: source.path) else {
            throw PreUpgradeBackupError.databaseMissing(source.lastPathComponent)
        }
        try fileManager.createDirectory(at: backupsRoot, withIntermediateDirectories: true)

        let createdAt = now()
        let target = makeUniqueDirectory(timestamp: createdAt, version: fromVersion)

        var copied: [String] = []
        var totalBytes: Int64 = 0
        // 主库 + WAL + SHM 必须一起复制，否则恢复时数据不一致
        for name in sidecarNames(mainFileName: source.lastPathComponent) {
            let fileURL = paths.root.appendingPathComponent(name, isDirectory: false)
            guard fileManager.fileExists(atPath: fileURL.path) else { continue }
            do {
                try fileManager.copyItem(at: fileURL, to: target.appendingPathComponent(name))
            } catch {
                // 复制失败：清掉半成品目录，避免被当成可用备份
                try? fileManager.removeItem(at: target)
                throw PreUpgradeBackupError.copyFailed(file: name, reason: error.localizedDescription)
            }
            copied.append(name)
            totalBytes += fileSize(at: target.appendingPathComponent(name))
        }

        let manifest = Manifest(
            id: target.lastPathComponent,
            fromVersion: fromVersion,
            createdAt: createdAt,
            files: copied,
            totalBytes: totalBytes
        )
        do {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: target.appendingPathComponent("manifest.json"), options: .atomic)
        } catch {
            try? fileManager.removeItem(at: target)
            throw PreUpgradeBackupError.copyFailed(file: "manifest.json", reason: error.localizedDescription)
        }
        copied.append("manifest.json")

        let removed = prune(keeping: target.lastPathComponent)
        return PreUpgradeBackupResult(
            id: target.lastPathComponent,
            directory: target,
            fromVersion: fromVersion,
            files: copied,
            totalBytes: totalBytes,
            removed: removed
        )
    }

    // MARK: - 内部

    private struct Manifest: Codable {
        let id: String
        let fromVersion: String
        let createdAt: Int64
        let files: [String]
        let totalBytes: Int64
    }

    private func sidecarNames(mainFileName: String) -> [String] {
        [mainFileName, mainFileName + "-wal", mainFileName + "-shm"]
    }

    /// 同一毫秒内多次备份时追加序号，保证目录唯一
    private func makeUniqueDirectory(timestamp: Int64, version: String) -> URL {
        let base = PreUpgradeBackupPolicy.directoryName(timestamp: timestamp, version: version)
        var candidate = base
        var suffix = 1
        var url = backupsRoot.appendingPathComponent(candidate, isDirectory: true)
        while fileManager.fileExists(atPath: url.path) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
            url = backupsRoot.appendingPathComponent(candidate, isDirectory: true)
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            // 目录建不出来时退回原名，后续 copy 会再报具体错误
            return url
        }
        return url
    }

    private func prune(keeping current: String) -> [String] {
        let expired = PreUpgradeBackupPolicy.expiredDirectoryNames(
            existing: existingBackupIDs(),
            keeping: retention,
            current: current
        )
        for name in expired {
            try? fileManager.removeItem(at: backupsRoot.appendingPathComponent(name, isDirectory: true))
        }
        return expired
    }

    private func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}

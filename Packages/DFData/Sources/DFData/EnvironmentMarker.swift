import Foundation
import DFCore

/// 数据目录归属标记。
/// 用于回答一个必须明确的问题：这个目录属于哪个环境。
public struct EnvironmentMarker: Codable, Sendable, Equatable {
    /// 标记格式版本，便于将来演进
    public let schema: Int
    public let environment: EnvironmentID
    public let createdAt: Int64
    /// 写入者标识（版本 + 构建号），便于追溯是谁认领的目录
    public let createdBy: String

    public init(schema: Int = 1, environment: EnvironmentID, createdAt: Int64, createdBy: String) {
        self.schema = schema
        self.environment = environment
        self.createdAt = createdAt
        self.createdBy = createdBy
    }
}

public enum EnvironmentMarkerError: Error, Equatable, Sendable {
    /// 目录非空但缺少标记：来历不明，拒绝启动（不自动认领）
    case missing(String)
    /// 标记属于另一个环境
    case mismatched(expected: EnvironmentID, found: EnvironmentID)
    /// 标记存在但不是合法 JSON / 字段不可识别
    case corrupted(String)
    /// 期望的根路径不是目录（而是普通文件等）
    case notADirectory(String)
    /// 写入失败（磁盘、权限等）
    case writeFailed(String)
}

public enum EnvironmentMarkerStore {
    public static let fileName = ".environment.json"

    public static func markerURL(root: URL) -> URL {
        root.appendingPathComponent(fileName, isDirectory: false)
    }

    /// 严格三态：空目录 → 写入标记；标记一致 → 通过；其余一律抛错。
    /// 任何情况下都不会"补写"或"认领"一个已有数据的目录。
    @discardableResult
    public static func verifyOrCreate(root: URL,
                                      expected: EnvironmentID,
                                      createdBy: String,
                                      now: Int64) throws -> EnvironmentMarker {
        let fm = FileManager.default
        let url = markerURL(root: root)

        if fm.fileExists(atPath: url.path) {
            let marker = try read(from: url)
            guard marker.environment == expected else {
                throw EnvironmentMarkerError.mismatched(expected: expected, found: marker.environment)
            }
            return marker
        }

        // 无标记：只有空目录（或目录不存在）才允许首次写入
        var entries: [String] = []
        if fm.fileExists(atPath: root.path) {
            // 根路径必须是目录；若是普通文件等，明确拒绝，不当成空目录
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw EnvironmentMarkerError.notADirectory(root.path)
            }
            do {
                entries = try fm.contentsOfDirectory(atPath: root.path)
            } catch {
                throw EnvironmentMarkerError.writeFailed(error.localizedDescription)
            }
        } else {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
        // 忽略自身的临时文件残留
        let meaningful = entries.filter { $0 != fileName && !$0.hasPrefix(fileName + ".tmp-") }
        guard meaningful.isEmpty else {
            throw EnvironmentMarkerError.missing(root.path)
        }

        let marker = EnvironmentMarker(environment: expected, createdAt: now, createdBy: createdBy)
        try writeAtomically(marker, to: url)
        return marker
    }

    public static func read(from url: URL) throws -> EnvironmentMarker {
        guard let data = try? Data(contentsOf: url) else {
            throw EnvironmentMarkerError.missing(url.path)
        }
        do {
            return try JSONDecoder().decode(EnvironmentMarker.self, from: data)
        } catch {
            throw EnvironmentMarkerError.corrupted(url.path)
        }
    }

    /// 原子写入：同目录临时文件 → fsync → rename 覆盖。
    /// 失败时清理临时文件，不留下半成品。
    public static func writeAtomically(_ marker: EnvironmentMarker, to url: URL) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        let tmp = directory.appendingPathComponent("\(fileName).tmp-\(UUID().uuidString)", isDirectory: false)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(marker)
        } catch {
            throw EnvironmentMarkerError.writeFailed(error.localizedDescription)
        }

        do {
            try data.write(to: tmp)
            if let handle = try? FileHandle(forWritingTo: tmp) {
                try? handle.synchronize()
                try? handle.close()
            }
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw EnvironmentMarkerError.writeFailed(error.localizedDescription)
        }
    }
}

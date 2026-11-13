import Foundation
import DFCore

/// 附件存储：内容寻址（SHA-256），同一文件重复写入自动去重。
/// 写入顺序固定为「先落文件，再写库」，避免出现"有记录无文件"。
public struct AttachmentStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func store(data: Data, fileExtension: String) throws -> StoredAttachment {
        let digest = SHA256.hash(data)
        let first = String(digest.prefix(2))
        let second = String(digest.dropFirst(2).prefix(2))
        let ext = fileExtension.isEmpty ? "bin" : fileExtension.lowercased()

        let directory = root
            .appendingPathComponent(first, isDirectory: true)
            .appendingPathComponent(second, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appendingPathComponent("\(digest).\(ext)")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try data.write(to: fileURL, options: [.atomic])
        }

        return StoredAttachment(
            sha256: digest,
            relativePath: "\(first)/\(second)/\(digest).\(ext)",
            byteSize: Int64(data.count)
        )
    }

    public func fileURL(forRelativePath path: String) -> URL {
        root.appendingPathComponent(path, isDirectory: false)
    }

    public func exists(relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(forRelativePath: relativePath).path)
    }

    public func remove(relativePath: String) throws {
        let url = fileURL(forRelativePath: relativePath)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// 扫描磁盘上存在但数据库中没有索引的文件（孤儿文件）。
    /// 只报告，不自动删除——用户数据不擅自丢弃。
    public func orphanFiles(knownRelativePaths: Set<String>) throws -> [String] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        var orphans: [String] = []

        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isRegular else { continue }

            let relative = url.path
                .replacingOccurrences(of: root.path, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !knownRelativePaths.contains(relative) {
                orphans.append(relative)
            }
        }
        return orphans.sorted()
    }
}

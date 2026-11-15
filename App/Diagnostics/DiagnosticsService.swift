import Foundation
import DFCore
import DFData

/// 诊断包与存储分类（W10-3 / D66、D70）。
///
/// 只统计"数量与体积"，不读取任何聊天/记忆正文；导出前再由 `DiagnosticRedactor` 兜底脱敏。
struct DiagnosticsService: Sendable {
    let database: AppDatabase
    let integrity: IntegrityChecker
    let appVersion: String
    let now: @Sendable () -> Int64

    init(
        database: AppDatabase,
        integrity: IntegrityChecker,
        appVersion: String,
        now: @escaping @Sendable () -> Int64 = { Clock.nowMillis() }
    ) {
        self.database = database
        self.integrity = integrity
        self.appVersion = appVersion
        self.now = now
    }

    /// 统计的表（存在才统计，避免旧库缺表时报错）
    private static let countedTables = [
        "conversations", "messages", "memories", "diary_entries", "personas",
        "attachments", "proactive_messages", "proposals", "astrbot_import_pending"
    ]

    func buildReport() async -> DiagnosticReport {
        let counts = await tableCounts()
        let storage = storageUsage()
        let check = try? integrity.run()

        var notes: [String] = []
        if let check {
            if !check.isHealthy { notes.append("完整性检查未通过：\(check.databaseCheck)") }
            if !check.missingAttachmentFiles.isEmpty {
                notes.append("缺失附件文件 \(check.missingAttachmentFiles.count) 个")
            }
            if !check.orphanAttachmentFiles.isEmpty {
                notes.append("游离附件文件 \(check.orphanAttachmentFiles.count) 个")
            }
        } else {
            notes.append("完整性检查执行失败")
        }

        return DiagnosticReport(
            appVersion: appVersion,
            schemaVersion: database.currentSchemaVersion,
            platform: "iOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            generatedAt: now(),
            counts: counts,
            storage: storage,
            healthy: check?.isHealthy ?? false,
            healthNotes: notes,
            freeBytes: freeBytes()
        )
    }

    /// 写入临时目录，返回可分享的文件 URL。
    func write(_ report: DiagnosticReport) throws -> URL {
        let markdown = DiagnosticExporter.markdown(report)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(DiagnosticExporter.fileName(at: report.generatedAt))
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - 统计

    private func tableCounts() async -> [String: Int] {
        await DatabaseStats.tableCounts(database, tables: Self.countedTables)
    }

    private func storageUsage() -> StorageUsage {
        let fileManager = FileManager.default
        let paths = database.paths
        var items: [StorageUsageItem] = [
            StorageUsageItem(
                key: "database",
                title: "数据库",
                bytes: Self.fileSize(paths.databaseURL, fileManager: fileManager)
                    + Self.fileSize(paths.databaseURL.appendingPathExtension("wal"), fileManager: fileManager)
                    + Self.fileSize(paths.databaseURL.appendingPathExtension("shm"), fileManager: fileManager)
            ),
            StorageUsageItem(
                key: "attachments",
                title: "附件",
                bytes: Self.directorySize(paths.attachmentsRoot, fileManager: fileManager)
            ),
            StorageUsageItem(
                key: "backups",
                title: "备份",
                bytes: Self.directorySize(
                    paths.workspace.appendingPathComponent("Backups", isDirectory: true),
                    fileManager: fileManager
                )
            )
        ]
        items.sort { $0.bytes > $1.bytes }
        return StorageUsage(items: items)
    }

    private func freeBytes() -> Int64? {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: database.paths.root.path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    private static func fileSize(_ url: URL, fileManager: FileManager) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func directorySize(_ url: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }
}

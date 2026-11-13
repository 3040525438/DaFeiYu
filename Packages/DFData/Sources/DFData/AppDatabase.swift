import Foundation
import GRDB
import DFCore

/// 数据库入口。负责建目录、开库、跑迁移。
public final class AppDatabase: @unchecked Sendable {
    public let dbQueue: DatabaseQueue
    public let paths: DatabasePaths

    public init(paths: DatabasePaths) throws {
        self.paths = paths

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.attachmentsRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.workspace, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.logs, withIntermediateDirectories: true)

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            // WAL 模式：异常退出后可恢复，且读写不互相阻塞
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }

        do {
            dbQueue = try DatabaseQueue(path: paths.databaseURL.path, configuration: configuration)
            try Migrations.migrator.migrate(dbQueue)
        } catch {
            throw DFError.database("无法打开本地数据库：\(error.localizedDescription)")
        }
    }

    /// 启动自检：返回 "ok" 表示结构完整
    public func quickCheck() throws -> String {
        do {
            return try dbQueue.read { db in
                try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "unknown"
            }
        } catch {
            throw DFError.database("数据库自检失败：\(error.localizedDescription)")
        }
    }

    public var currentSchemaVersion: String {
        let value = try? dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1")
        }
        return value.flatMap { $0 } ?? "none"
    }
}

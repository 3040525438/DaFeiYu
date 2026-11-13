import Foundation
import GRDB
import DFCore

/// 数据库完整性模式。
/// 当 `schema_meta` 与 `grdb_migrations` 不自洽时，进入只读模式：允许读取，禁止继续写入。
public enum DatabaseIntegrityMode: Equatable, Sendable {
    case healthy
    case readOnly(reason: String)

    public var isReadOnly: Bool {
        if case .readOnly = self { return true }
        return false
    }
}

/// 数据库入口。负责建目录、开库、跑迁移。
public final class AppDatabase: @unchecked Sendable {
    /// 不要直接使用它写入：所有写入必须走 `write(_:)`，否则只读降级会被绕过。
    /// 读取可以直接用 `read` 或本属性。
    let dbQueue: DatabaseQueue
    public let paths: DatabasePaths
    /// 启动自检结果；只读模式下调用方应先询问 `isReadOnly`
    public private(set) var integrityMode: DatabaseIntegrityMode = .healthy

    public var isReadOnly: Bool { integrityMode.isReadOnly }

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
            // 每个连接都必须开启外键（D-C：不是只在某次迁移里临时设置）
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        do {
            dbQueue = try DatabaseQueue(path: paths.databaseURL.path, configuration: configuration)
            try Migrations.migrator.migrate(dbQueue)
        } catch {
            throw DFError.database("无法打开本地数据库：\(error.localizedDescription)")
        }

        // 启动自检：台账与 meta 必须自洽；不一致时降级为只读，而不是崩溃
        do {
            _ = try dbQueue.read { db in try SchemaMeta.verify(db) }
        } catch {
            integrityMode = .readOnly(reason: error.localizedDescription)
        }
    }

    /// 写入前的守卫：只读模式下拒绝写入
    public func assertWritable() throws {
        if case .readOnly(let reason) = integrityMode {
            throw DFError.database("数据库处于只读模式，请先恢复备份：\(reason)")
        }
    }

    /// 统一写入入口：只读降级时**先拒绝**，不会静默成功。
    /// 所有仓储的写操作都必须经过这里。
    public func write<T>(_ updates: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try assertWritable()
        return try await dbQueue.write(updates)
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
        // 版本判断只认 schema_meta（不与 grdb_migrations 形成双事实源）
        if let version = try? dbQueue.read({ db in try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion) }),
           let value = version {
            return value
        }
        // 回退：按规范顺序取最后一项（不使用 rowid）
        let applied = (try? dbQueue.read { db in try SchemaMeta.appliedIdentifiers(db) }) ?? []
        if let ordered = try? MigrationLedger.validatedPrefix(applied: applied), let last = ordered.last {
            return last
        }
        return "none"
    }
}

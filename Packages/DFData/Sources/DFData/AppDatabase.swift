import Foundation
import GRDB
import DFCore

/// 数据库完整性模式。
/// - `healthy`：结构与台账自洽，可读可写；
/// - `readOnly`：迁移已完成但自检不通过，允许读取、禁止写入；
/// - `migrationFailed`：升级事务失败（已整体回滚），允许读取旧结构、禁止一切写入，
///   等待用户在界面上明确触发重试。
public enum DatabaseIntegrityMode: Equatable, Sendable {
    case healthy
    case readOnly(reason: String)
    case migrationFailed(reason: String)

    public var isReadOnly: Bool {
        switch self {
        case .healthy: return false
        case .readOnly, .migrationFailed: return true
        }
    }

    /// 禁止写入的原因；`nil` 表示可写
    public var writeBlockReason: String? {
        switch self {
        case .healthy: return nil
        case .readOnly(let reason): return "只读模式：\(reason)"
        case .migrationFailed(let reason): return "升级未完成：\(reason)"
        }
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

    /// 迁移失败的具体原因（仅 `migrationFailed` 状态非空）
    public var migrationFailureReason: String? {
        if case .migrationFailed(let reason) = integrityMode { return reason }
        return nil
    }

    /// 迁移器工厂：允许测试注入"首次失败、重试成功"的场景，生产环境固定返回 `Migrations.migrator`
    private let makeMigrator: @Sendable () -> DatabaseMigrator

    public convenience init(paths: DatabasePaths) throws {
        try self.init(paths: paths, makeMigrator: { Migrations.migrator })
    }

    init(paths: DatabasePaths, makeMigrator: @escaping @Sendable () -> DatabaseMigrator) throws {
        self.paths = paths
        self.makeMigrator = makeMigrator

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
        } catch {
            throw DFError.database("无法打开本地数据库：\(error.localizedDescription)")
        }

        upgradeOnLaunch()
    }

    /// 启动升级：先迁移，再做台账自检。
    /// 迁移失败**不抛错**：事务已整体回滚，库仍是升级前结构，
    /// 这里降级为 `migrationFailed`（禁止一切写入），由界面提示恢复与重试。
    private func upgradeOnLaunch() {
        do {
            try makeMigrator().migrate(dbQueue)
        } catch {
            integrityMode = .migrationFailed(reason: error.localizedDescription)
            return
        }

        do {
            _ = try dbQueue.read { db in try SchemaMeta.verify(db) }
            try dbQueue.read { db in try SchemaMeta.verifyRequiredObjects(db) }
        } catch {
            integrityMode = .readOnly(reason: error.localizedDescription)
        }
    }

    /// 由用户明确触发的一次升级重试（不会自动循环重试）。
    /// - 重试前先只读检查迁移台账可访问；
    /// - 成功后必须再次通过台账/摘要自检，才恢复可写；
    /// - 失败继续保持 `migrationFailed`，并把错误抛给界面展示。
    public func retryMigration() async throws {
        guard case .migrationFailed = integrityMode else { return }

        // 重试前检查：台账必须可读（只读，不写入任何内容）
        _ = try await dbQueue.read { db in try SchemaMeta.appliedIdentifiers(db) }

        do {
            try makeMigrator().migrate(dbQueue)
            _ = try await dbQueue.read { db in try SchemaMeta.verify(db) }
            try await dbQueue.read { db in try SchemaMeta.verifyRequiredObjects(db) }
            integrityMode = .healthy
        } catch {
            integrityMode = .migrationFailed(reason: error.localizedDescription)
            throw DFError.database("数据库升级重试失败：\(error.localizedDescription)")
        }
    }

    /// 写入前的守卫：只读 / 升级未完成时拒绝写入（错误信息区分两种状态）
    public func assertWritable() throws {
        if let reason = integrityMode.writeBlockReason {
            throw DFError.database("数据库当前不可写入，已拒绝本次写入（\(reason)），请先恢复备份或重试升级")
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
        // 注意：`try?` 会把 `String?` 展平为 `String?`，此处只绑定一次
        if let value = try? dbQueue.read({ db in try SchemaMeta.value(db, key: SchemaMetaKey.schemaVersion) }) {
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

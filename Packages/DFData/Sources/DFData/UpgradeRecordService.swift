import Foundation
import GRDB
import DFCore

/// 升级审计记录（D67）：每次升级尝试留痕，失败后可追溯原因与备份。
///
/// 边界：
/// - 只写 `upgrade_records`，不改业务表；
/// - 状态迁移必须符合 `UpgradeGuard.canTransition`（running → succeeded/failed，failed → rolledBack）；
/// - `pre_upgrade_backup_id` 只登记真实存在的备份清单 id，由调用方保证。
public final class UpgradeRecordService: @unchecked Sendable {
    public struct Record: Sendable, Equatable, Identifiable {
        public var id: String
        public var fromVersion: String
        public var toVersion: String
        public var batch: String
        public var status: UpgradeAuditStatus
        public var backupID: String?
        public var error: String?
        public var startedAt: Int64
        public var finishedAt: Int64?

        public var isFinished: Bool { finishedAt != nil }
    }

    public enum RecordError: Error, Equatable, CustomStringConvertible {
        case notFound(String)
        case invalidTransition(from: String, to: String)

        public var description: String {
            switch self {
            case .notFound(let id):
                return "升级记录不存在：\(id)"
            case .invalidTransition(let from, let to):
                return "升级记录状态不允许从 \(from) 变为 \(to)"
            }
        }
    }

    private let database: AppDatabase
    private let now: @Sendable () -> Int64

    public init(database: AppDatabase, now: @escaping @Sendable () -> Int64 = { Clock.nowMillis() }) {
        self.database = database
        self.now = now
    }

    // MARK: - 写入

    @discardableResult
    public func start(
        fromVersion: String,
        toVersion: String,
        batch: String = "",
        backupID: String? = nil,
        integrityJSON: String = "{}"
    ) async throws -> Record {
        try await database.write { db in
            let id = UUID().uuidString
            let at = self.now()
            try db.execute(
                sql: """
                INSERT INTO upgrade_records
                    (id, from_version, to_version, batch, status, pre_upgrade_backup_id,
                     integrity_json, error, started_at, finished_at)
                VALUES (?, ?, ?, ?, 'running', ?, ?, NULL, ?, NULL)
                """,
                arguments: [id, fromVersion, toVersion, batch, backupID, integrityJSON, at]
            )
            return Record(
                id: id,
                fromVersion: fromVersion,
                toVersion: toVersion,
                batch: batch,
                status: .running,
                backupID: backupID,
                error: nil,
                startedAt: at,
                finishedAt: nil
            )
        }
    }

    @discardableResult
    public func finish(id: String, status: UpgradeAuditStatus, error: String? = nil) async throws -> Record {
        try await database.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM upgrade_records WHERE id = ?",
                arguments: [id]
            ) else {
                throw RecordError.notFound(id)
            }
            let current = UpgradeAuditStatus(rawValue: try row.decode(String.self, forColumn: "status")) ?? .running
            guard UpgradeGuard.canTransition(from: current, to: status) else {
                throw RecordError.invalidTransition(from: current.rawValue, to: status.rawValue)
            }
            try db.execute(
                sql: """
                UPDATE upgrade_records
                   SET status = ?, error = ?, finished_at = ?
                 WHERE id = ?
                """,
                arguments: [status.rawValue, error, self.now(), id]
            )
            return try self.load(db, id: id)
        }
    }

    // MARK: - 读取

    public func recent(limit: Int = 20) async throws -> [Record] {
        try await database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM upgrade_records
                 ORDER BY started_at DESC
                 LIMIT ?
                """,
                arguments: [max(1, limit)]
            ).map { try self.decode($0) }
        }
    }

    public func record(id: String) async throws -> Record? {
        try await database.dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM upgrade_records WHERE id = ?",
                arguments: [id]
            ) else { return nil }
            return try self.decode(row)
        }
    }

    // MARK: - 内部

    private func load(_ db: Database, id: String) throws -> Record {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM upgrade_records WHERE id = ?",
            arguments: [id]
        ) else {
            throw RecordError.notFound(id)
        }
        return try decode(row)
    }

    private func decode(_ row: Row) throws -> Record {
        Record(
            id: try row.decode(String.self, forColumn: "id"),
            fromVersion: try row.decode(String.self, forColumn: "from_version"),
            toVersion: try row.decode(String.self, forColumn: "to_version"),
            batch: Self.optionalString(row, "batch") ?? "",
            status: UpgradeAuditStatus(rawValue: try row.decode(String.self, forColumn: "status")) ?? .running,
            backupID: Self.optionalString(row, "pre_upgrade_backup_id"),
            error: Self.optionalString(row, "error"),
            startedAt: try row.decode(Int64.self, forColumn: "started_at"),
            finishedAt: Self.optionalInt64(row, "finished_at")
        )
    }

    private static func optionalString(_ row: Row, _ column: String) -> String? {
        guard row.hasColumn(column) else { return nil }
        return String.fromDatabaseValue(row[column])
    }

    private static func optionalInt64(_ row: Row, _ column: String) -> Int64? {
        guard row.hasColumn(column) else { return nil }
        return Int64.fromDatabaseValue(row[column])
    }
}

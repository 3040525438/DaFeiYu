import Foundation
import GRDB
import DFCore

/// 用户数据导出结果（D59）
public struct UserDataExportSummary: Sendable, Equatable {
    public let url: URL
    public let counts: [String: Int]
    public let byteSize: Int64
    public let exportedAt: Int64

    public var totalRows: Int { counts.values.reduce(0, +) }
}

public enum UserDataExportError: Error, Equatable, CustomStringConvertible {
    case nothingToExport
    case writeFailed(String)

    public var description: String {
        switch self {
        case .nothingToExport:
            return "没有可导出的数据"
        case .writeFailed(let reason):
            return "导出失败：\(reason)"
        }
    }
}

/// 把用户数据导出为单个 JSON 文件（D59）。
///
/// 边界：
/// - 只读数据库，不改任何业务数据；
/// - 只导出白名单表（聊天、记忆、日记、人格与关系、附件元数据、提案）；
/// - 不导出 `settings` / `local_models` / 内部队列表，凭据列按列名黑名单剔除；
/// - 附件二进制本身不导出，只导出元数据与转写文本。
public final class UserDataExporter: @unchecked Sendable {
    public static let format = "dafeiyu.user-export.v1"

    /// 导出白名单：只包含用户可感知的数据
    public static let exportedTables = [
        "conversations",
        "messages",
        "message_tags",
        "message_references",
        "memories",
        "memory_versions",
        "memory_sources",
        "memory_links",
        "diary_entries",
        "persona_items",
        "persona_versions",
        "relationship_profile",
        "relationship_stage_history",
        "relationship_milestones",
        "attachments",
        "attachment_texts",
        "proposals"
    ]

    /// 任何表中都不导出的列（凭据类）
    public static let excludedColumnNames: Set<String> = [
        "api_key", "apikey", "token", "access_token", "refresh_token",
        "secret", "password", "passcode_hash"
    ]

    private let database: AppDatabase
    private let now: @Sendable () -> Int64

    public init(database: AppDatabase, now: @escaping @Sendable () -> Int64 = { Clock.nowMillis() }) {
        self.database = database
        self.now = now
    }

    /// 导出到指定目录；不传时写到 `Workspace/Exports`。
    @discardableResult
    public func export(to directory: URL? = nil) async throws -> UserDataExportSummary {
        let exportedAt = now()
        let schemaVersion = database.currentSchemaVersion

        let snapshot = try await database.dbQueue.read { db -> (tables: [String: Any], counts: [String: Int]) in
            var tables: [String: Any] = [:]
            var counts: [String: Int] = [:]
            for table in UserDataExporter.exportedTables {
                guard try db.tableExists(table) else { continue }
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table)")
                var exported: [[String: Any]] = []
                exported.reserveCapacity(rows.count)
                for row in rows {
                    var object: [String: Any] = [:]
                    for (column, value) in row.asDictionary {
                        guard !UserDataExporter.excludedColumnNames.contains(column.lowercased()) else { continue }
                        object[column] = UserDataExporter.jsonSafe(value)
                    }
                    exported.append(object)
                }
                tables[table] = exported
                counts[table] = rows.count
            }
            return (tables, counts)
        }

        guard snapshot.counts.values.contains(where: { $0 > 0 }) else {
            // 空库导出没有意义，也避免用户拿到一个空文件误以为成功
            throw UserDataExportError.nothingToExport
        }

        let payload: [String: Any] = [
            "format": UserDataExporter.format,
            "exportedAt": exportedAt,
            "schemaVersion": schemaVersion,
            "counts": snapshot.counts,
            "tables": snapshot.tables
        ]
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw UserDataExportError.writeFailed(error.localizedDescription)
        }

        let targetDirectory = directory
            ?? database.paths.workspace.appendingPathComponent("Exports", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
            let fileURL = targetDirectory.appendingPathComponent("dafeiyu-export-\(exportedAt).json")
            try data.write(to: fileURL, options: .atomic)
            return UserDataExportSummary(
                url: fileURL,
                counts: snapshot.counts,
                byteSize: Int64(data.count),
                exportedAt: exportedAt
            )
        } catch {
            throw UserDataExportError.writeFailed(error.localizedDescription)
        }
    }

    /// `DatabaseValue` → JSON 可序列化值
    static func jsonSafe(_ value: DatabaseValue) -> Any {
        switch value.storage {
        case .null:
            return NSNull()
        case .int64(let number):
            return number
        case .double(let number):
            return number
        case .string(let text):
            return text
        case .blob(let data):
            // 二进制只以 base64 兜底表示，正常导出表中不应出现
            return ["base64": data.base64EncodedString()]
        }
    }
}

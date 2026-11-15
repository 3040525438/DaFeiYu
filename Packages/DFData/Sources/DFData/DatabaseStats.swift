import Foundation
import GRDB

/// 诊断用的只读统计（W10-3）。
///
/// 放在 DFData 内，App 层就不需要直接依赖 GRDB。
public enum DatabaseStats {
    /// 统计给定表的行数；不存在的表直接跳过（旧库缺表不报错）。
    public static func tableCounts(_ database: AppDatabase, tables: [String]) async -> [String: Int] {
        (try? await database.dbQueue.read { db -> [String: Int] in
            var result: [String: Int] = [:]
            for table in tables where try db.tableExists(table) {
                result[table] = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? 0
            }
            return result
        }) ?? [:]
    }
}

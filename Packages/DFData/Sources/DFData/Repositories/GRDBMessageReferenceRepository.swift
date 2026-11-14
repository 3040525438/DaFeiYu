import Foundation
import GRDB
import DFCore

/// 引用关系仓储：批量写入与批量读取（避免 N+1）。
public struct GRDBMessageReferenceRepository: MessageReferenceRepository, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func insertBatch(_ references: [MessageReference]) async throws {
        guard !references.isEmpty else { return }
        do {
            try await database.write { db in
                // 复合主键 (message_id, ref_message_id, relation) 冲突时幂等忽略
                for reference in references {
                    try reference.insert(db, onConflict: .ignore)
                }
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func references(for messageIDs: [String]) async throws -> [MessageReference] {
        guard !messageIDs.isEmpty else { return [] }
        do {
            return try await database.dbQueue.read { db in
                try MessageReference
                    .filter(messageIDs.contains(Column("message_id")))
                    .order(
                        Column("message_id").asc,
                        Column("created_at").asc,
                        Column("ref_message_id").asc
                    )
                    .fetchAll(db)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func messages(ids: [String]) async throws -> [Message] {
        guard !ids.isEmpty else { return [] }
        do {
            return try await database.dbQueue.read { db in
                // 故意不过滤 deleted_at：调用方需要区分"已软删"与"查不到"。
                // 这是按 id 集合的定点查询（非时间线翻页），顺序按 created_at + id 稳定即可。
                try Message
                    .filter(ids.contains(Column("id")))
                    .order(Column("created_at").asc, Column("id").asc)
                    .fetchAll(db)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }
}

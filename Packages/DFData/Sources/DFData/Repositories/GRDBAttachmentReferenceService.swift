import Foundation
import GRDB
import DFCore

/// 附件引用检查与清理（D57）。
///
/// 与 `GRDBAttachmentRepository` 的分工：
/// - 仓储负责单条附件的事实读写（link / unlink / softDelete）；
/// - 本服务负责**删除前的引用判定**与批量清理策略，避免界面各自实现一套判断。
public struct GRDBAttachmentReferenceService: AttachmentReferenceService, Sendable {
    private let database: AppDatabase
    private let repository: GRDBAttachmentRepository

    public init(database: AppDatabase) {
        self.database = database
        self.repository = GRDBAttachmentRepository(database: database)
    }

    public func references(attachmentID: String) async throws -> AttachmentReference {
        do {
            return try await database.dbQueue.read { db in
                guard try Self.attachmentExists(db, id: attachmentID) else {
                    throw AttachmentReferenceError.notFound
                }
                return try Self.reference(db, attachmentID: attachmentID)
            }
        } catch let error as DatabaseError {
            throw DFError.database(error.message ?? "数据库操作失败")
        }
    }

    public func library(
        includeDeleted: Bool,
        limit: Int,
        offset: Int
    ) async throws -> [AttachmentLibraryItem] {
        do {
            return try await database.dbQueue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT a.id, a.sha256, a.kind, a.rel_path, a.byte_size, a.mime,
                           a.width, a.height, a.duration_ms, a.thumbnail_rel_path,
                           a.created_at, a.deleted_at,
                           (SELECT COUNT(*) FROM message_attachments ma
                            WHERE ma.attachment_id = a.id) AS total_refs,
                           (SELECT COUNT(*) FROM message_attachments ma
                            JOIN messages m ON m.id = ma.message_id
                            WHERE ma.attachment_id = a.id
                              AND m.deleted_at IS NULL) AS live_refs
                    FROM attachments a
                    WHERE (? = 1 OR a.deleted_at IS NULL)
                    ORDER BY a.created_at DESC, a.id ASC
                    LIMIT ? OFFSET ?
                    """,
                    arguments: [
                        includeDeleted ? 1 : 0,
                        min(max(limit, 1), 200),
                        max(offset, 0)
                    ]
                )
                return try rows.map { row in
                    AttachmentLibraryItem(
                        record: try Self.decodeRecord(row),
                        totalReferences: try row.decode(Int.self, forColumn: "total_refs"),
                        liveReferences: try row.decode(Int.self, forColumn: "live_refs")
                    )
                }
            }
        } catch let error as DatabaseError {
            throw DFError.database(error.message ?? "数据库操作失败")
        }
    }

    public func record(id: String) async throws -> AttachmentRecord? {
        do {
            return try await database.dbQueue.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT id, sha256, kind, rel_path, byte_size, mime,
                           width, height, duration_ms, thumbnail_rel_path,
                           created_at, deleted_at
                    FROM attachments WHERE id = ?
                    """,
                    arguments: [id]
                ) else { return nil }
                return try Self.decodeRecord(row)
            }
        } catch let error as DatabaseError {
            throw DFError.database(error.message ?? "数据库操作失败")
        }
    }

    public func deleteAttachment(id: String, at millis: Int64, force: Bool) async throws {
        do {
            try await database.write { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT deleted_at FROM attachments WHERE id = ?",
                    arguments: [id]
                ) else {
                    throw AttachmentReferenceError.notFound
                }
                // 已软删：幂等返回，不刷新首次删除时间
                guard Int64.fromDatabaseValue(row["deleted_at"]) == nil else { return }

                let live = try Self.liveMessageIDs(db, attachmentID: id)
                if !live.isEmpty && !force {
                    throw AttachmentReferenceError.inUse(messageIDs: live)
                }
                if !live.isEmpty {
                    // 强制删除：先解除全部关联（含已删除消息的陈旧关联）
                    try db.execute(
                        sql: "DELETE FROM message_attachments WHERE attachment_id = ?",
                        arguments: [id]
                    )
                }
                try db.execute(
                    sql: """
                    UPDATE attachments
                    SET deleted_at = COALESCE(deleted_at, ?),
                        deleted_reason = COALESCE(deleted_reason, 'user_cleanup')
                    WHERE id = ?
                    """,
                    arguments: [millis, id]
                )
            }
        } catch let error as DatabaseError {
            throw DFError.database(error.message ?? "数据库操作失败")
        }
    }

    @discardableResult
    public func unlinkAll(attachmentID: String) async throws -> Int {
        do {
            return try await database.write { db in
                guard try Self.attachmentExists(db, id: attachmentID) else {
                    throw AttachmentReferenceError.notFound
                }
                try db.execute(
                    sql: "DELETE FROM message_attachments WHERE attachment_id = ?",
                    arguments: [attachmentID]
                )
                return db.changesCount
            }
        } catch let error as DatabaseError {
            throw DFError.database(error.message ?? "数据库操作失败")
        }
    }

    public func cleanupCandidates(before millis: Int64, limit: Int) async throws -> [AttachmentRecord] {
        // 复用仓储口径：未软删、早于 millis、完全没有关联
        try await repository.unreferenced(before: millis, limit: limit)
    }

    public func cleanup(
        attachmentIDs: [String],
        at millis: Int64
    ) async throws -> (deleted: Int, skippedInUse: Int) {
        let unique = Set(attachmentIDs).sorted()
        guard !unique.isEmpty else { return (0, 0) }

        do {
            return try await database.write { db in
                var deleted = 0
                var skipped = 0
                for id in unique {
                    guard let row = try Row.fetchOne(
                        db,
                        sql: "SELECT deleted_at FROM attachments WHERE id = ?",
                        arguments: [id]
                    ) else {
                        continue // 已不存在的附件直接跳过，批量操作保持幂等
                    }
                    guard Int64.fromDatabaseValue(row["deleted_at"]) == nil else {
                        continue
                    }
                    let live = try Self.liveMessageIDs(db, attachmentID: id)
                    guard live.isEmpty else {
                        // 被活消息引用：绝不静默删除
                        skipped += 1
                        continue
                    }
                    try db.execute(
                        sql: """
                        UPDATE attachments
                        SET deleted_at = ?, deleted_reason = 'auto_cleanup'
                        WHERE id = ?
                        """,
                        arguments: [millis, id]
                    )
                    deleted += 1
                }
                return (deleted, skipped)
            }
        } catch let error as DatabaseError {
            throw DFError.database(error.message ?? "数据库操作失败")
        }
    }

    // MARK: - 内部

    private static func attachmentExists(_ db: Database, id: String) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT 1 FROM attachments WHERE id = ?",
            arguments: [id]
        ) != nil
    }

    private static func reference(
        _ db: Database,
        attachmentID: String
    ) throws -> AttachmentReference {
        let messageIDs = try String.fetchAll(
            db,
            sql: """
            SELECT message_id FROM message_attachments
            WHERE attachment_id = ? ORDER BY message_id ASC
            """,
            arguments: [attachmentID]
        )
        let live = try liveMessageIDs(db, attachmentID: attachmentID)
        return AttachmentReference(
            attachmentID: attachmentID,
            totalReferences: messageIDs.count,
            liveReferences: live.count,
            messageIDs: messageIDs
        )
    }

    /// 附件记录解码（列名与 `GRDBAttachmentRepository.columns` 保持一致）
    private static func decodeRecord(_ row: Row) throws -> AttachmentRecord {
        AttachmentRecord(
            id: try row.decode(String.self, forColumn: "id"),
            sha256: try row.decode(String.self, forColumn: "sha256"),
            kind: try row.decode(String.self, forColumn: "kind"),
            relPath: try row.decode(String.self, forColumn: "rel_path"),
            byteSize: try row.decode(Int64.self, forColumn: "byte_size"),
            mime: try row.decode(String.self, forColumn: "mime"),
            createdAt: try row.decode(Int64.self, forColumn: "created_at"),
            width: Int.fromDatabaseValue(row["width"]),
            height: Int.fromDatabaseValue(row["height"]),
            durationMs: Int.fromDatabaseValue(row["duration_ms"]),
            thumbnailRelPath: String.fromDatabaseValue(row["thumbnail_rel_path"]),
            deletedAt: Int64.fromDatabaseValue(row["deleted_at"])
        )
    }

    private static func liveMessageIDs(_ db: Database, attachmentID: String) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
            SELECT ma.message_id FROM message_attachments ma
            JOIN messages m ON m.id = ma.message_id
            WHERE ma.attachment_id = ? AND m.deleted_at IS NULL
            ORDER BY ma.message_id ASC
            """,
            arguments: [attachmentID]
        )
    }
}

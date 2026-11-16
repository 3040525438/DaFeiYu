import Foundation
import GRDB
import DFCore

/// 表情包仓储的 GRDB 实现。
///
/// 口径：
/// - 图片 / GIF 只保存附件 id，文件本体由 `AttachmentStore` 内容寻址去重；
/// - 同一附件重复导入时直接返回既有的未删除表情（重复资源识别）；
/// - 删除是软删索引，不删磁盘文件，也不删附件行。
public struct GRDBStickerRepository: StickerRepository {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - 包

    public func packs() async throws -> [StickerPack] {
        try await database.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM sticker_packs ORDER BY created_at ASC")
                .map(Self.decodePack)
        }
    }

    @discardableResult
    public func ensurePack(
        name: String,
        source: StickerSource,
        sourceURL: String?,
        license: String?
    ) async throws -> StickerPack {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StickerError.emptyName }
        return try await database.write { db in
            if let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM sticker_packs WHERE name = ? AND source = ?",
                arguments: [trimmed, source.rawValue]
            ) {
                return Self.decodePack(row)
            }
            let now = Clock.nowMillis()
            let pack = StickerPack(
                name: trimmed,
                source: source,
                sourceURL: sourceURL,
                license: license,
                createdAt: now,
                updatedAt: now
            )
            try db.execute(
                sql: """
                INSERT INTO sticker_packs (id, name, source, source_url, license, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [pack.id, pack.name, pack.source.rawValue, pack.sourceURL, pack.license, now, now]
            )
            return pack
        }
    }

    // MARK: - 表情写入

    @discardableResult
    public func insert(_ sticker: NewSticker, at millis: Int64) async throws -> Sticker {
        let name = sticker.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw StickerError.emptyName }
        switch sticker.kind {
        case .emoji:
            guard let emoji = sticker.emoji, !emoji.isEmpty else { throw StickerError.missingEmoji }
        case .staticImage, .gif:
            guard let attachmentID = sticker.attachmentID, !attachmentID.isEmpty else {
                throw StickerError.missingAttachment
            }
            _ = attachmentID
        }

        return try await database.write { db in
            // 重复资源识别：同一附件已有未删除表情时直接复用，不产生重复行
            if sticker.kind != .emoji, let attachmentID = sticker.attachmentID,
               let row = try Row.fetchOne(
                   db,
                   sql: "SELECT * FROM stickers WHERE attachment_id = ? AND deleted_at IS NULL LIMIT 1",
                   arguments: [attachmentID]
               ) {
                return Self.decodeSticker(row)
            }
            // Emoji 去重：同一字符只保留一条
            if sticker.kind == .emoji, let emoji = sticker.emoji,
               let row = try Row.fetchOne(
                   db,
                   sql: "SELECT * FROM stickers WHERE kind = 'emoji' AND emoji = ? AND deleted_at IS NULL LIMIT 1",
                   arguments: [emoji]
               ) {
                return Self.decodeSticker(row)
            }

            let record = Sticker(
                packID: sticker.packID,
                kind: sticker.kind,
                name: name,
                tags: sticker.tags,
                emoji: sticker.emoji,
                attachmentID: sticker.attachmentID,
                semantics: sticker.semantics,
                semanticsSource: sticker.semanticsSource,
                createdAt: millis,
                updatedAt: millis
            )
            try db.execute(
                sql: """
                INSERT INTO stickers
                    (id, pack_id, kind, name, tags, emoji, attachment_id, semantics, semantics_source,
                     is_favorite, created_at, updated_at, deleted_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, NULL)
                """,
                arguments: [
                    record.id, record.packID, record.kind.rawValue, record.name, record.tags,
                    record.emoji, record.attachmentID, record.semantics,
                    record.semanticsSource.rawValue, millis, millis
                ]
            )
            return record
        }
    }

    // MARK: - 表情读取

    public func sticker(id: String) async throws -> Sticker? {
        try await database.dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM stickers WHERE id = ?", arguments: [id])
                .map(Self.decodeSticker)
        }
    }

    public func stickers(
        packID: String?,
        kind: StickerKind?,
        limit: Int,
        offset: Int
    ) async throws -> [Sticker] {
        // 分支写死参数形态，避免把协议类型当作数组元素类型使用
        let sqlBase = "SELECT * FROM stickers WHERE deleted_at IS NULL"
        let order = " ORDER BY created_at DESC, name ASC LIMIT ? OFFSET ?"
        return try await database.dbQueue.read { db in
            let rows: [Row]
            switch (packID, kind) {
            case let (pack?, kind?):
                rows = try Row.fetchAll(
                    db,
                    sql: sqlBase + " AND pack_id = ? AND kind = ?" + order,
                    arguments: [pack, kind.rawValue, max(0, limit), max(0, offset)]
                )
            case let (pack?, nil):
                rows = try Row.fetchAll(
                    db,
                    sql: sqlBase + " AND pack_id = ?" + order,
                    arguments: [pack, max(0, limit), max(0, offset)]
                )
            case let (nil, kind?):
                rows = try Row.fetchAll(
                    db,
                    sql: sqlBase + " AND kind = ?" + order,
                    arguments: [kind.rawValue, max(0, limit), max(0, offset)]
                )
            case (nil, nil):
                rows = try Row.fetchAll(
                    db,
                    sql: sqlBase + order,
                    arguments: [max(0, limit), max(0, offset)]
                )
            }
            return try rows.map(Self.decodeSticker)
        }
    }

    public func count(kind: StickerKind?) async throws -> Int {
        try await database.dbQueue.read { db in
            if let kind {
                return try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM stickers WHERE deleted_at IS NULL AND kind = ?",
                    arguments: [kind.rawValue]
                ) ?? 0
            }
            return try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM stickers WHERE deleted_at IS NULL"
            ) ?? 0
        }
    }

    public func search(query: String, limit: Int) async throws -> [Sticker] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let pattern = "%\(trimmed)%"
        return try await database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM stickers
                 WHERE deleted_at IS NULL
                   AND (name LIKE ? OR tags LIKE ? OR semantics LIKE ?)
                 ORDER BY is_favorite DESC, created_at DESC
                 LIMIT ?
                """,
                arguments: [pattern, pattern, pattern, max(0, limit)]
            ).map(Self.decodeSticker)
        }
    }

    public func favorites(limit: Int) async throws -> [Sticker] {
        try await database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM stickers
                 WHERE deleted_at IS NULL AND is_favorite = 1
                 ORDER BY updated_at DESC
                 LIMIT ?
                """,
                arguments: [max(0, limit)]
            ).map(Self.decodeSticker)
        }
    }

    public func recent(limit: Int) async throws -> [Sticker] {
        try await database.dbQueue.read { db in
            // 同一表情只出现一次，取最近一次使用时间
            try Row.fetchAll(
                db,
                sql: """
                SELECT s.* FROM stickers s
                  JOIN (SELECT sticker_id, MAX(used_at) AS last_used
                          FROM sticker_usage GROUP BY sticker_id) u
                    ON u.sticker_id = s.id
                 WHERE s.deleted_at IS NULL
                 ORDER BY u.last_used DESC
                 LIMIT ?
                """,
                arguments: [max(0, limit)]
            ).map(Self.decodeSticker)
        }
    }

    // MARK: - 更新

    public func setFavorite(id: String, isFavorite: Bool, at millis: Int64) async throws {
        let affected = try await database.write { db in
            try db.execute(
                sql: "UPDATE stickers SET is_favorite = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL",
                arguments: [isFavorite ? 1 : 0, millis, id]
            )
            return db.changesCount
        }
        guard affected > 0 else { throw StickerError.notFound }
    }

    public func updateSemantics(
        id: String,
        semantics: String,
        source: StickerSemanticsSource,
        at millis: Int64
    ) async throws {
        let affected = try await database.write { db in
            try db.execute(
                sql: """
                UPDATE stickers
                   SET semantics = ?, semantics_source = ?, updated_at = ?
                 WHERE id = ? AND deleted_at IS NULL
                """,
                arguments: [semantics, source.rawValue, millis, id]
            )
            return db.changesCount
        }
        guard affected > 0 else { throw StickerError.notFound }
    }

    public func rename(id: String, name: String, tags: String, at millis: Int64) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StickerError.emptyName }
        let affected = try await database.write { db in
            try db.execute(
                sql: "UPDATE stickers SET name = ?, tags = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL",
                arguments: [trimmed, tags, millis, id]
            )
            return db.changesCount
        }
        guard affected > 0 else { throw StickerError.notFound }
    }

    public func delete(id: String, at millis: Int64) async throws {
        let affected = try await database.write { db in
            try db.execute(
                sql: "UPDATE stickers SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL",
                arguments: [millis, millis, id]
            )
            return db.changesCount
        }
        // 已删除视为幂等成功，但完全不存在时如实报错
        if affected == 0 {
            let exists = try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM stickers WHERE id = ?", arguments: [id]) ?? 0
            }
            guard exists > 0 else { throw StickerError.notFound }
        }
    }

    // MARK: - 使用记录

    public func recordUsage(stickerID: String, messageID: String?, at millis: Int64) async throws {
        try await database.write { db in
            // 同一毫秒可能重复记录：主键冲突时更新时间戳，不抛错
            try db.execute(
                sql: """
                INSERT INTO sticker_usage (sticker_id, used_at, message_id)
                VALUES (?, ?, ?)
                ON CONFLICT(sticker_id, used_at) DO UPDATE SET message_id = excluded.message_id
                """,
                arguments: [stickerID, millis, messageID]
            )
        }
    }

    public func usage(stickerID: String, limit: Int) async throws -> [StickerUsage] {
        try await database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT sticker_id, used_at, message_id FROM sticker_usage
                 WHERE sticker_id = ?
                 ORDER BY used_at DESC
                 LIMIT ?
                """,
                arguments: [stickerID, max(0, limit)]
            ).map { row in
                StickerUsage(
                    stickerID: try row.decode(String.self, forColumn: "sticker_id"),
                    usedAt: try row.decode(Int64.self, forColumn: "used_at"),
                    messageID: try row.decodeIfPresent(String.self, forColumn: "message_id")
                )
            }
        }
    }

    // MARK: - 解码

    private static func decodePack(_ row: Row) throws -> StickerPack {
        let rawSource = try row.decode(String.self, forColumn: "source")
        return StickerPack(
            id: try row.decode(String.self, forColumn: "id"),
            name: try row.decode(String.self, forColumn: "name"),
            source: StickerSource(rawValue: rawSource) ?? .local,
            sourceURL: try row.decodeIfPresent(String.self, forColumn: "source_url"),
            license: try row.decodeIfPresent(String.self, forColumn: "license"),
            createdAt: try row.decode(Int64.self, forColumn: "created_at"),
            updatedAt: try row.decode(Int64.self, forColumn: "updated_at")
        )
    }

    private static func decodeSticker(_ row: Row) throws -> Sticker {
        let rawKind = try row.decode(String.self, forColumn: "kind")
        let rawSource = try row.decode(String.self, forColumn: "semantics_source")
        let favorite = try row.decodeIfPresent(Int.self, forColumn: "is_favorite") ?? 0
        return Sticker(
            id: try row.decode(String.self, forColumn: "id"),
            packID: try row.decodeIfPresent(String.self, forColumn: "pack_id"),
            kind: StickerKind(rawValue: rawKind) ?? .staticImage,
            name: try row.decode(String.self, forColumn: "name"),
            tags: try row.decode(String.self, forColumn: "tags"),
            emoji: try row.decodeIfPresent(String.self, forColumn: "emoji"),
            attachmentID: try row.decodeIfPresent(String.self, forColumn: "attachment_id"),
            semantics: try row.decode(String.self, forColumn: "semantics"),
            semanticsSource: StickerSemanticsSource(rawValue: rawSource) ?? .none,
            isFavorite: favorite != 0,
            createdAt: try row.decode(Int64.self, forColumn: "created_at"),
            updatedAt: try row.decode(Int64.self, forColumn: "updated_at"),
            deletedAt: try row.decodeIfPresent(Int64.self, forColumn: "deleted_at")
        )
    }
}

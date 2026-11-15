import Foundation
import GRDB
import DFCore

/// 跨域统一检索的唯一实现（D25）。
///
/// 数据来源全部是既有 FTS 表，不新增索引、不改迁移：
/// - `message_fts`：聊天消息（排除已软删 / 已撤回）；
/// - `memory_fts`：三主体记忆（排除已软删）；
/// - `diary_fts`：日记正文（排除已软删）；
/// - `attachment_text_fts`：OCR / 语音转写（排除附件已软删）。
///
/// 刻意**不过滤会话归档状态**：归档会话的消息仍可被搜到（D51），
/// 否则用户会误以为归档等于数据消失。
public struct GRDBUnifiedSearchRepository: UnifiedSearchRepository, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func search(
        query: String,
        domains: Set<SearchDomain>,
        limitPerDomain: Int
    ) async throws -> [UnifiedSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !domains.isEmpty else { return [] }

        // 中文按 bigram 切分后 AND 组合；每个词加引号，避免用户输入被当成 FTS 语法
        let tokens = V2Memory.bigram(trimmed)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard !tokens.isEmpty else { return [] }
        let match = tokens.map { "\"\($0)\"" }.joined(separator: " AND ")
        let limit = min(max(limitPerDomain, 1), 50)
        let snippetLength = 80

        do {
            return try await database.dbQueue.read { db in
                var hits: [UnifiedSearchHit] = []
                for domain in SearchDomain.allCases where domains.contains(domain) {
                    switch domain {
                    case .message:
                        guard try db.tableExists("message_fts") else { continue }
                        hits += try Self.messageHits(
                            db,
                            match: match,
                            query: trimmed,
                            limit: limit,
                            snippetLength: snippetLength
                        )
                    case .memory:
                        guard try db.tableExists("memory_fts") else { continue }
                        hits += try Self.memoryHits(
                            db,
                            match: match,
                            query: trimmed,
                            limit: limit,
                            snippetLength: snippetLength
                        )
                    case .diary:
                        guard try db.tableExists("diary_fts") else { continue }
                        hits += try Self.diaryHits(
                            db,
                            match: match,
                            query: trimmed,
                            limit: limit,
                            snippetLength: snippetLength
                        )
                    case .attachment:
                        guard try db.tableExists("attachment_text_fts") else { continue }
                        hits += try Self.attachmentHits(
                            db,
                            match: match,
                            query: trimmed,
                            limit: limit,
                            snippetLength: snippetLength
                        )
                    }
                }
                return hits
            }
        } catch let error as DatabaseError {
            throw DFError.database(error.message ?? "数据库操作失败")
        }
    }

    // MARK: - 各域查询

    private static func messageHits(
        _ db: Database,
        match: String,
        query: String,
        limit: Int,
        snippetLength: Int
    ) throws -> [UnifiedSearchHit] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT message_fts.message_id, message_fts.conversation_id,
                   bm25(message_fts) AS score,
                   m.text AS body, m.role AS role, m.created_at AS created_at,
                   c.title AS conversation_title
            FROM message_fts
            JOIN messages m ON m.id = message_fts.message_id
            LEFT JOIN conversations c ON c.id = m.conversation_id
            WHERE message_fts MATCH ?
              AND m.deleted_at IS NULL
              AND m.revoked_at IS NULL
            ORDER BY score ASC
            LIMIT ?
            """,
            arguments: [match, limit]
        )

        return try rows.map { row in
            let messageID = try row.decode(String.self, forColumn: "message_id")
            let conversationID = try row.decode(String.self, forColumn: "conversation_id")
            let body = try row.decode(String.self, forColumn: "body")
            let role = try row.decode(String.self, forColumn: "role")
            let conversationTitle = String.fromDatabaseValue(row["conversation_title"]) ?? ""
            let speaker = role == "user" ? "我" : "大肥鱼"
            let base = conversationTitle.isEmpty ? "聊天" : conversationTitle
            return UnifiedSearchHit(
                domain: .message,
                targetID: messageID,
                title: "\(base) · \(speaker)",
                snippet: SearchSnippet.make(text: body, query: query, maxLength: snippetLength),
                score: try row.decode(Double.self, forColumn: "score"),
                conversationID: conversationID,
                messageID: messageID,
                createdAt: Int64.fromDatabaseValue(row["created_at"])
            )
        }
    }

    private static func memoryHits(
        _ db: Database,
        match: String,
        query: String,
        limit: Int,
        snippetLength: Int
    ) throws -> [UnifiedSearchHit] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT memory_fts.memory_id, bm25(memory_fts) AS score,
                   mem.title AS title, mem.content AS content, mem.first_seen_at AS created_at
            FROM memory_fts
            JOIN memories mem ON mem.id = memory_fts.memory_id
            WHERE memory_fts MATCH ?
              AND mem.deleted_at IS NULL
              AND mem.status <> 'deleted'
            ORDER BY score ASC
            LIMIT ?
            """,
            arguments: [match, limit]
        )

        return try rows.map { row in
            let memoryID = try row.decode(String.self, forColumn: "memory_id")
            let title = String.fromDatabaseValue(row["title"]) ?? ""
            let content = String.fromDatabaseValue(row["content"]) ?? ""
            return UnifiedSearchHit(
                domain: .memory,
                targetID: memoryID,
                title: title.isEmpty ? "记忆" : title,
                snippet: SearchSnippet.make(text: content, query: query, maxLength: snippetLength),
                score: try row.decode(Double.self, forColumn: "score"),
                createdAt: Int64.fromDatabaseValue(row["created_at"])
            )
        }
    }

    private static func diaryHits(
        _ db: Database,
        match: String,
        query: String,
        limit: Int,
        snippetLength: Int
    ) throws -> [UnifiedSearchHit] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT diary_fts.diary_id, bm25(diary_fts) AS score,
                   d.entry_date, d.title, d.content, d.created_at
            FROM diary_fts
            JOIN diary_entries d ON d.id = diary_fts.diary_id
            WHERE diary_fts MATCH ?
              AND d.deleted_at IS NULL
            ORDER BY score ASC
            LIMIT ?
            """,
            arguments: [match, limit]
        )

        return try rows.map { row in
            let diaryID = try row.decode(String.self, forColumn: "diary_id")
            let entryDate = try row.decode(String.self, forColumn: "entry_date")
            let title = String.fromDatabaseValue(row["title"]) ?? ""
            let content = String.fromDatabaseValue(row["content"]) ?? ""
            return UnifiedSearchHit(
                domain: .diary,
                targetID: diaryID,
                title: title.isEmpty ? entryDate : "\(entryDate) · \(title)",
                snippet: SearchSnippet.make(text: content, query: query, maxLength: snippetLength),
                score: try row.decode(Double.self, forColumn: "score"),
                diaryDate: entryDate,
                createdAt: Int64.fromDatabaseValue(row["created_at"])
            )
        }
    }

    private static func attachmentHits(
        _ db: Database,
        match: String,
        query: String,
        limit: Int,
        snippetLength: Int
    ) throws -> [UnifiedSearchHit] {
        // 同一附件可能有多条派生文本（OCR / 转写）：按附件聚合，只保留最相关的一条
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT attachment_text_fts.attachment_id,
                   bm25(attachment_text_fts) AS score,
                   a.kind AS kind, a.created_at AS created_at,
                   (SELECT t.text FROM attachment_texts t
                     WHERE t.attachment_id = attachment_text_fts.attachment_id
                     ORDER BY t.updated_at DESC LIMIT 1) AS body,
                   (SELECT m.conversation_id FROM message_attachments ma
                      JOIN messages m ON m.id = ma.message_id
                     WHERE ma.attachment_id = attachment_text_fts.attachment_id
                       AND m.deleted_at IS NULL
                     ORDER BY m.created_at ASC LIMIT 1) AS conversation_id,
                   (SELECT ma.message_id FROM message_attachments ma
                      JOIN messages m ON m.id = ma.message_id
                     WHERE ma.attachment_id = attachment_text_fts.attachment_id
                       AND m.deleted_at IS NULL
                     ORDER BY m.created_at ASC LIMIT 1) AS message_id
            FROM attachment_text_fts
            JOIN attachments a ON a.id = attachment_text_fts.attachment_id
            WHERE attachment_text_fts MATCH ?
              AND a.deleted_at IS NULL
            ORDER BY score ASC
            LIMIT ?
            """,
            arguments: [match, limit]
        )

        var hits: [UnifiedSearchHit] = []
        var seen = Set<String>()
        for row in rows {
            let attachmentID = try row.decode(String.self, forColumn: "attachment_id")
            // 同一附件只保留首次（最相关）命中
            guard seen.insert(attachmentID).inserted else { continue }
            let kind = String.fromDatabaseValue(row["kind"]) ?? "file"
            let body = String.fromDatabaseValue(row["body"]) ?? ""
            hits.append(
                UnifiedSearchHit(
                    domain: .attachment,
                    targetID: attachmentID,
                    title: "附件 · \(kind)",
                    snippet: SearchSnippet.make(text: body, query: query, maxLength: snippetLength),
                    score: try row.decode(Double.self, forColumn: "score"),
                    conversationID: String.fromDatabaseValue(row["conversation_id"]),
                    messageID: String.fromDatabaseValue(row["message_id"]),
                    createdAt: Int64.fromDatabaseValue(row["created_at"])
                )
            )
        }
        return hits
    }
}

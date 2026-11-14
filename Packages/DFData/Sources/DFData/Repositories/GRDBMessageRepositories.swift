import Foundation
import GRDB
import DFCore

enum GRDBErrorMapper {
    static func map(_ error: Error) -> Error {
        if let error = error as? DFError { return error }
        // 业务型错误必须原样抛出：被包成 DFError.database 后调用方再也认不出错误语义
        if let error = error as? ConversationAdminError { return error }
        if let error = error as? MessageInteractionError { return error }
        if let error = error as? MultimodalError { return error }
        if let error = error as? LocalModelError { return error }
        if let error = error as? DiaryError { return error }
        if let error = error as? MemoryError { return error }
        if let error = error as? BackupError { return error }
        if let error = error as? DatabaseError {
            return DFError.database(error.message ?? "数据库操作失败")
        }
        return DFError.database(error.localizedDescription)
    }
}

public struct GRDBConversationRepository: ConversationRepository, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func ensureMainConversation(title: String) async throws -> Conversation {
        do {
            return try await database.write { db in
                if let existing = try Conversation
                    .filter(Column("kind") == "main")
                    .fetchOne(db) {
                    return existing
                }
                let conversation = Conversation(title: title)
                try conversation.insert(db)
                return conversation
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func conversation(id: String) async throws -> Conversation? {
        do {
            return try await database.dbQueue.read { db in
                try Conversation.fetchOne(db, key: id)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func touch(id: String, at millis: Int64) async throws {
        do {
            try await database.write { db in
                try db.execute(
                    sql: "UPDATE conversations SET updated_at = ? WHERE id = ?",
                    arguments: [millis, id]
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }
}

public struct GRDBMessageRepository: MessageRepository, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func insert(_ message: Message) async throws {
        do {
            try await database.write { db in
                try message.insert(db)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func update(_ message: Message) async throws {
        do {
            try await database.write { db in
                try message.update(db)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func message(id: String) async throws -> Message? {
        do {
            return try await database.dbQueue.read { db in
                try Message.fetchOne(db, key: id)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func recentMessages(in conversationID: String, limit: Int) async throws -> [Message] {
        do {
            return try await database.dbQueue.read { db in
                let rows = try Message
                    .filter(Column("conversation_id") == conversationID)
                    .filter(Column("deleted_at") == nil)
                    .order(Column("created_at").desc, Column("rowid").desc)
                    .limit(max(0, limit))
                    .fetchAll(db)
                return Array(rows.reversed())
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func count(in conversationID: String) async throws -> Int {
        do {
            return try await database.dbQueue.read { db in
                try Message
                    .filter(Column("conversation_id") == conversationID)
                    .filter(Column("deleted_at") == nil)
                    .fetchCount(db)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    // MARK: - 分页（双键游标）

    public func page(in conversationID: String, before: PageCursor?, limit: Int) async throws -> MessagePage {
        // 上限保护：越界不报错，按 1...200 夹取
        let clamped = min(max(limit, 1), 200)
        do {
            return try await database.dbQueue.read { db in
                // `? = 0` 作为"无游标"开关，避免动态拼接两套 SQL
                let hasCursor = before == nil ? 0 : 1
                let cursorCreated = before?.createdAt ?? 0
                let cursorRowid = before?.rowid ?? 0
                let rows = try MessageRow.fetchAll(
                    db,
                    sql: """
                    SELECT messages.*, messages.rowid AS _rid
                    FROM messages
                    WHERE messages.conversation_id = ?
                      AND messages.deleted_at IS NULL
                      AND (? = 0 OR (messages.created_at < ?
                                     OR (messages.created_at = ? AND messages.rowid < ?)))
                    ORDER BY messages.created_at DESC, messages.rowid DESC
                    LIMIT ?
                    """,
                    arguments: [
                        conversationID, hasCursor, cursorCreated, cursorCreated, cursorRowid, clamped + 1
                    ]
                )

                let hasMore = rows.count > clamped
                let pageRows = Array(rows.prefix(clamped))
                // SQL 取降序，返回前反转为升序（与 recentMessages 的升序语义一致）
                let ascending = Array(pageRows.reversed())
                let nextCursor = hasMore
                    ? ascending.first.map { PageCursor(createdAt: $0.message.createdAt, rowid: $0.rowid) }
                    : nil
                return MessagePage(
                    items: ascending.map(\.message),
                    nextCursor: nextCursor,
                    hasMore: hasMore
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    // MARK: - 按组查询

    public func messages(inGroup groupID: String) async throws -> [Message] {
        do {
            return try await database.dbQueue.read { db in
                try MessageRow.fetchAll(
                    db,
                    sql: """
                    SELECT messages.*, messages.rowid AS _rid
                    FROM messages
                    WHERE messages.group_id = ?
                    ORDER BY messages.created_at ASC, messages.rowid ASC
                    """,
                    arguments: [groupID]
                ).map(\.message)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    // MARK: - 定向正文更新（取消保留正文用）

    public func updateAssistantText(
        _ text: String,
        for messageID: String,
        expectedStatus: MessageStatus = .sending
    ) async throws -> AssistantTextUpdateResult {
        do {
            return try await database.write { db in
                // 单事务内完成"存在性 + 状态校验 + 写入"，避免读后写之间的覆盖窗口
                guard let currentStatus = try String.fetchOne(
                    db,
                    sql: "SELECT status FROM messages WHERE id = ?",
                    arguments: [messageID]
                ) else {
                    return .notFound
                }
                guard currentStatus == expectedStatus.rawValue else {
                    return .statusMismatch
                }
                try db.execute(
                    sql: """
                    UPDATE messages SET text = ?
                    WHERE id = ? AND status = ? AND deleted_at IS NULL
                    """,
                    arguments: [text, messageID, expectedStatus.rawValue]
                )
                guard db.changesCount == 1 else { return .statusMismatch }

                // 正文变更必须同步全文索引，避免"库里能读到、搜索查不到"
                if let conversationID = try String.fetchOne(
                    db,
                    sql: "SELECT conversation_id FROM messages WHERE id = ?",
                    arguments: [messageID]
                ) {
                    try MessageIndexer.index(
                        db: db,
                        messageID: messageID,
                        conversationID: conversationID,
                        text: text
                    )
                }
                return .updated
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }
}

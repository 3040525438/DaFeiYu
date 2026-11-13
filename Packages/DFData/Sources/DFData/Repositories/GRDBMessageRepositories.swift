import Foundation
import GRDB
import DFCore

enum GRDBErrorMapper {
    static func map(_ error: Error) -> Error {
        if let error = error as? DFError { return error }
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
            return try await database.dbQueue.write { db in
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
            try await database.dbQueue.write { db in
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
            try await database.dbQueue.write { db in
                try message.insert(db)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func update(_ message: Message) async throws {
        do {
            try await database.dbQueue.write { db in
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
}

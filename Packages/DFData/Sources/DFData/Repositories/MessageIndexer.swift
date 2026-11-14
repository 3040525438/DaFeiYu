import Foundation
import GRDB
import DFCore

/// 消息全文索引（`message_fts`）的唯一写入口径。
///
/// 表结构来自 `v8_chat_v2`：不挂 external content，文本由应用层转为中文 bigram 后写入。
/// 所有"消息正文变化"的路径（新消息、编辑、撤回、删除）都必须走这里，
/// 避免出现"库里有正文、索引里查不到"的分叉。
enum MessageIndexer {
    /// 先删后插，保证同一条消息只有一份索引
    static func index(db: Database, messageID: String, conversationID: String, text: String) throws {
        guard try db.tableExists("message_fts") else { return }
        try db.execute(
            sql: "DELETE FROM message_fts WHERE message_id = ?",
            arguments: [messageID]
        )
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try db.execute(
            sql: "INSERT INTO message_fts (message_id, conversation_id, text_bigram) VALUES (?, ?, ?)",
            arguments: [messageID, conversationID, V2Memory.bigram(trimmed)]
        )
    }

    static func remove(db: Database, messageID: String) throws {
        guard try db.tableExists("message_fts") else { return }
        try db.execute(
            sql: "DELETE FROM message_fts WHERE message_id = ?",
            arguments: [messageID]
        )
    }
}

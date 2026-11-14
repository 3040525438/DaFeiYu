import GRDB
import DFCore

// GRDB 记录映射。列名由各模型内的 CodingKeys 决定（统一 snake_case）。

/// 按列名解码字符串枚举，遇到未知值抛出明确错误，而不是静默回落。
private func decodeEnum<T: RawRepresentable>(
    _ type: T.Type,
    _ column: String,
    in row: Row
) throws -> T where T.RawValue == String {
    let raw = try row.decode(String.self, forColumn: column)
    guard let value = T(rawValue: raw) else {
        throw DFError.database("无法识别的枚举值：\(column)=\(raw)")
    }
    return value
}

/// 可空列的读取。
///
/// 不用 `row.decodeIfPresent(_:forColumn:)`：`Row` 同时遵循 `Decoder`，
/// 该方法会被解析到 `Decodable` 的同名重载上。这里直接读 `DatabaseValue`
/// 再用 `fromDatabaseValue` 转换，既能区分 NULL 与缺失列，也不受重载解析影响。
private extension Row {
    func optionalString(_ column: String) -> String? {
        guard hasColumn(column) else { return nil }
        return String.fromDatabaseValue(self[column])
    }

    func optionalInt64(_ column: String) -> Int64? {
        guard hasColumn(column) else { return nil }
        return Int64.fromDatabaseValue(self[column])
    }

    func optionalInt(_ column: String) -> Int? {
        guard hasColumn(column) else { return nil }
        return Int.fromDatabaseValue(self[column])
    }
}

extension Conversation: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "conversations"
}

/// `messages` 的读取映射。
///
/// 自定义 `init(row:)` 只影响 GRDB 的行解码，**不影响** `Decodable.init(from:)` 的合成，
/// 因此 `Codable` 行为保持不变（JSON 导出/迁移仍走合成实现）。
///
/// 兼容两种库结构：
/// - v3 及以后：`group_id` / `seq_in_group` 存在，正常解码；
/// - v2 降级态或旧导入库：两列不存在，用 `hasColumn` 兜底为 `nil`，不崩溃。
extension Message: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "messages"

    public init(row: Row) throws {
        id = try row.decode(String.self, forColumn: "id")
        clientUUID = try row.decode(String.self, forColumn: "client_uuid")
        conversationID = try row.decode(String.self, forColumn: "conversation_id")
        role = try decodeEnum(MessageRole.self, "role", in: row)
        kind = try decodeEnum(MessageKind.self, "kind", in: row)
        text = try row.decode(String.self, forColumn: "text")
        status = try decodeEnum(MessageStatus.self, "status", in: row)
        origin = try decodeEnum(MessageOrigin.self, "origin", in: row)
        replyToID = row.optionalString("reply_to_id")
        createdAt = try row.decode(Int64.self, forColumn: "created_at")
        sentAt = row.optionalInt64("sent_at")
        modelConfigID = row.optionalString("model_config_id")
        emotionStateID = row.optionalString("emotion_state_id")
        deletedAt = row.optionalInt64("deleted_at")
        groupID = row.optionalString("group_id")
        seqInGroup = row.optionalInt("seq_in_group")
    }
}

extension MessageGroup: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "message_groups"
}

extension MessageReference: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "message_references"
}

/// 携带 SQLite `rowid` 的消息行。
///
/// `rowid` 只作为分页游标的次级排序键存在于查询层，
/// **不进入** `Message` 业务模型，避免污染 Codable 与写入路径。
struct MessageRow: FetchableRecord {
    let message: Message
    let rowid: Int64

    init(row: Row) throws {
        message = try Message(row: row)
        rowid = try row.decode(Int64.self, forColumn: "_rid")
    }
}

extension Persona: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "personas"
}

extension PersonaItem: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "persona_items"
}

extension PersonaVersion: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "persona_versions"
}

extension ModelConfig: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "model_configs"
}

extension AttachmentRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "attachments"
}

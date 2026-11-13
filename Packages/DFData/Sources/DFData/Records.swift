import GRDB
import DFCore

// GRDB 记录映射。列名由各模型内的 CodingKeys 决定（统一 snake_case）。

extension Conversation: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "conversations"
}

extension Message: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "messages"
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

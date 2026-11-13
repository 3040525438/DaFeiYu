import Foundation

public enum PersonaKind: String, Codable, Sendable {
    case core
    case outer
}

/// 人格档案。核心人格 isLocked = true，仓储层不提供修改入口。
public struct Persona: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: PersonaKind
    public var name: String
    public var isLocked: Bool
    public var currentVersion: Int
    public var createdAt: Int64
    public var updatedAt: Int64

    public init(
        id: String = UUID().uuidString,
        kind: PersonaKind,
        name: String,
        isLocked: Bool,
        currentVersion: Int = 1,
        createdAt: Int64 = Clock.nowMillis(),
        updatedAt: Int64 = Clock.nowMillis()
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.isLocked = isLocked
        self.currentVersion = currentVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case name
        case isLocked = "is_locked"
        case currentVersion = "current_version"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// 人格条目：核心人格的各个段落，以及外围人格的可演进特征
public struct PersonaItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var personaID: String
    public var section: String
    public var key: String
    public var value: String
    public var confidence: Double
    public var weight: Double
    public var source: String
    public var updatedAt: Int64

    public init(
        id: String = UUID().uuidString,
        personaID: String,
        section: String,
        key: String,
        value: String,
        confidence: Double = 1.0,
        weight: Double = 1.0,
        source: String = "user",
        updatedAt: Int64 = Clock.nowMillis()
    ) {
        self.id = id
        self.personaID = personaID
        self.section = section
        self.key = key
        self.value = value
        self.confidence = confidence
        self.weight = weight
        self.source = source
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case personaID = "persona_id"
        case section
        case key
        case value
        case confidence
        case weight
        case source
        case updatedAt = "updated_at"
    }
}

/// 人格版本快照（迁移与人工编辑都会留档）
public struct PersonaVersion: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var personaID: String
    public var version: Int
    public var snapshotJSON: String
    public var changeReason: String
    public var changedBy: String
    public var createdAt: Int64

    public init(
        id: String = UUID().uuidString,
        personaID: String,
        version: Int,
        snapshotJSON: String,
        changeReason: String,
        changedBy: String,
        createdAt: Int64 = Clock.nowMillis()
    ) {
        self.id = id
        self.personaID = personaID
        self.version = version
        self.snapshotJSON = snapshotJSON
        self.changeReason = changeReason
        self.changedBy = changedBy
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case personaID = "persona_id"
        case version
        case snapshotJSON = "snapshot_json"
        case changeReason = "change_reason"
        case changedBy = "changed_by"
        case createdAt = "created_at"
    }
}

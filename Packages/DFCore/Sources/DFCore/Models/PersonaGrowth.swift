import Foundation

// MARK: - 人格成长提案（W6 / P-05、P-11、决策 30–32）

/// 提案草稿：AI 只能提案，不能直接改人格。
public struct PersonaGrowthDraft: Sendable, Equatable {
    public var personaID: String
    /// 已有条目：提案修改它；为空表示新增条目
    public var itemID: String?
    public var section: String
    public var key: String
    public var fromValue: String
    public var toValue: String
    public var reason: String
    /// 证据（对话/记忆引用），JSON 文本
    public var evidenceJSON: String

    public init(
        personaID: String,
        itemID: String? = nil,
        section: String,
        key: String,
        fromValue: String = "",
        toValue: String,
        reason: String,
        evidenceJSON: String = "[]"
    ) {
        self.personaID = personaID
        self.itemID = itemID
        self.section = section
        self.key = key
        self.fromValue = fromValue
        self.toValue = toValue
        self.reason = reason
        self.evidenceJSON = evidenceJSON
    }
}

public struct PersonaGrowthProposal: Sendable, Equatable, Identifiable {
    public var id: String
    public var personaID: String
    public var itemID: String?
    public var section: String
    public var key: String
    public var fromValue: String
    public var toValue: String
    public var reason: String
    public var evidenceJSON: String
    /// pending / approved / rejected
    public var status: String
    public var createdAt: Int64
    public var resolvedAt: Int64?
    public var resolutionNote: String?

    public init(
        id: String,
        personaID: String,
        itemID: String?,
        section: String,
        key: String,
        fromValue: String,
        toValue: String,
        reason: String,
        evidenceJSON: String,
        status: String,
        createdAt: Int64,
        resolvedAt: Int64?,
        resolutionNote: String?
    ) {
        self.id = id
        self.personaID = personaID
        self.itemID = itemID
        self.section = section
        self.key = key
        self.fromValue = fromValue
        self.toValue = toValue
        self.reason = reason
        self.evidenceJSON = evidenceJSON
        self.status = status
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
        self.resolutionNote = resolutionNote
    }
}

public enum PersonaGrowthError: Error, Equatable, CustomStringConvertible {
    case personaNotFound(String)
    case coreProtected(String)
    case invalidDraft(String)
    case proposalNotFound(String)
    case proposalResolved(String)
    case itemNotFound(String)
    case versionNotFound(personaID: String, version: Int)
    case invalidSnapshot(String)

    public var description: String {
        switch self {
        case .personaNotFound(let id): return "人格不存在：\(id)"
        case .coreProtected(let name): return "核心人格受写保护，不能由 AI 提案修改：\(name)"
        case .invalidDraft(let reason): return "提案内容不合法：\(reason)"
        case .proposalNotFound(let id): return "提案不存在：\(id)"
        case .proposalResolved(let status): return "提案已处理：\(status)"
        case .itemNotFound(let id): return "人格条目不存在：\(id)"
        case .versionNotFound(let personaID, let version):
            return "人格 \(personaID) 没有版本 \(version)"
        case .invalidSnapshot(let reason): return "人格版本快照无法解析：\(reason)"
        }
    }
}

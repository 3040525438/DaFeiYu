import Foundation

// MARK: - 记忆（W8）

public enum MemoryScope: String, Codable, Sendable, CaseIterable {
    case user
    case shared
    /// 键值仍是 `self`（与 v2 迁移的 CHECK 口径一致），只是 Swift 里不能用关键字作 case 名
    case selfScope = "self"
}

/// 记忆来源引用：一条记忆可以有多处出处，删除来源时可据此定位（D19）。
public struct MemorySourceRef: Sendable, Equatable {
    public var sourceType: String
    public var sourceID: String
    public var excerpt: String
    public var at: Int64?

    public init(sourceType: String, sourceID: String, excerpt: String = "", at: Int64? = nil) {
        self.sourceType = sourceType
        self.sourceID = sourceID
        self.excerpt = excerpt
        self.at = at
    }
}

public struct MemoryRecord: Sendable, Equatable, Identifiable {
    public var id: String
    public var type: String
    public var title: String
    public var content: String
    /// 旧口径的重要度文本（low / normal / high）
    public var importance: String
    public var importanceScore: Double?
    public var importanceSource: String
    public var salience: Double
    public var confidence: Double
    public var status: String
    public var scope: MemoryScope
    public var layer: String
    public var category: String
    public var sourceKind: String
    public var epistemicStatus: String
    public var version: Int
    public var dedupeKey: String?
    public var heat: String
    public var classificationStatus: String
    public var createdAt: Int64
    public var updatedAt: Int64
    public var firstSeenAt: Int64
    public var lastRecalledAt: Int64?
    public var recallCount: Int
    public var archivedAt: Int64?
    public var deletedAt: Int64?

    public var isDeleted: Bool { deletedAt != nil }
    public var isArchived: Bool { archivedAt != nil }

    public init(
        id: String,
        type: String,
        title: String,
        content: String,
        importance: String,
        importanceScore: Double?,
        importanceSource: String,
        salience: Double,
        confidence: Double,
        status: String,
        scope: MemoryScope,
        layer: String,
        category: String,
        sourceKind: String,
        epistemicStatus: String,
        version: Int,
        dedupeKey: String?,
        heat: String,
        classificationStatus: String,
        createdAt: Int64,
        updatedAt: Int64,
        firstSeenAt: Int64,
        lastRecalledAt: Int64?,
        recallCount: Int,
        archivedAt: Int64?,
        deletedAt: Int64?
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.content = content
        self.importance = importance
        self.importanceScore = importanceScore
        self.importanceSource = importanceSource
        self.salience = salience
        self.confidence = confidence
        self.status = status
        self.scope = scope
        self.layer = layer
        self.category = category
        self.sourceKind = sourceKind
        self.epistemicStatus = epistemicStatus
        self.version = version
        self.dedupeKey = dedupeKey
        self.heat = heat
        self.classificationStatus = classificationStatus
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.firstSeenAt = firstSeenAt
        self.lastRecalledAt = lastRecalledAt
        self.recallCount = recallCount
        self.archivedAt = archivedAt
        self.deletedAt = deletedAt
    }
}

/// 新建记忆的输入。
public struct MemoryDraft: Sendable, Equatable {
    public var type: String
    public var title: String
    public var content: String
    public var scope: MemoryScope
    public var layer: String
    public var category: String
    public var sourceKind: String
    public var epistemicStatus: String
    public var importance: String
    public var confidence: Double
    public var salience: Double
    public var dedupeKey: String?
    public var sources: [MemorySourceRef]

    public init(
        type: String = "fact",
        title: String,
        content: String,
        scope: MemoryScope = .shared,
        layer: String = "semantic",
        category: String = "fact",
        sourceKind: String = "real_interaction",
        epistemicStatus: String = "observed",
        importance: String = "normal",
        confidence: Double = 0.5,
        salience: Double = 0.5,
        dedupeKey: String? = nil,
        sources: [MemorySourceRef] = []
    ) {
        self.type = type
        self.title = title
        self.content = content
        self.scope = scope
        self.layer = layer
        self.category = category
        self.sourceKind = sourceKind
        self.epistemicStatus = epistemicStatus
        self.importance = importance
        self.confidence = confidence
        self.salience = salience
        self.dedupeKey = dedupeKey
        self.sources = sources
    }
}

public struct MemoryVersionRecord: Sendable, Equatable, Identifiable {
    public var id: String
    public var memoryID: String
    public var version: Int
    public var title: String
    public var content: String
    public var changeReason: String
    public var changedBy: String
    public var createdAt: Int64

    public init(
        id: String,
        memoryID: String,
        version: Int,
        title: String,
        content: String,
        changeReason: String,
        changedBy: String,
        createdAt: Int64
    ) {
        self.id = id
        self.memoryID = memoryID
        self.version = version
        self.title = title
        self.content = content
        self.changeReason = changeReason
        self.changedBy = changedBy
        self.createdAt = createdAt
    }
}

public enum MemoryError: Error, Equatable, CustomStringConvertible {
    case notFound
    case emptyContent
    case invalidScope(String)
    case invalidLayer(String)
    case invalidChangedBy(String)

    public var description: String {
        switch self {
        case .notFound: return "记忆不存在"
        case .emptyContent: return "记忆内容不能为空"
        case .invalidScope(let value): return "非法的记忆归属：\(value)"
        case .invalidLayer(let value): return "非法的记忆层级：\(value)"
        case .invalidChangedBy(let value): return "非法的修改者：\(value)"
        }
    }
}

public protocol MemoryRepository: Sendable {
    /// 写入记忆。`dedupeKey` 命中未删除记忆时**不新建**，只补来源并返回既有记录。
    @discardableResult
    func insert(_ draft: MemoryDraft, at millis: Int64) async throws -> MemoryRecord

    func memory(id: String) async throws -> MemoryRecord?
    /// 修改正文：版本 +1，并写入 `memory_versions` 全量快照与全文索引。
    @discardableResult
    func updateContent(
        id: String,
        title: String,
        content: String,
        changedBy: String,
        reason: String,
        at millis: Int64
    ) async throws -> MemoryRecord

    func setScope(id: String, scope: MemoryScope, evidence: String, at millis: Int64) async throws
    func setImportance(
        id: String,
        score: Double,
        source: String,
        reason: String,
        at millis: Int64
    ) async throws
    func addSource(memoryID: String, source: MemorySourceRef) async throws
    func sources(memoryID: String) async throws -> [MemorySourceRef]

    /// 列表：默认排除已删除与已归档
    func memories(
        scope: MemoryScope?,
        layer: String?,
        includeArchived: Bool,
        limit: Int,
        offset: Int
    ) async throws -> [MemoryRecord]

    func search(query: String, scope: MemoryScope?, limit: Int) async throws -> [MemoryRecord]
    func versions(memoryID: String) async throws -> [MemoryVersionRecord]

    func archive(id: String, at millis: Int64) async throws
    func softDelete(id: String, at millis: Int64) async throws
    /// 按来源批量删除（D19：可按来源清理）
    @discardableResult
    func softDelete(sourceType: String, sourceID: String, at millis: Int64) async throws -> Int
    func restore(id: String) async throws

    func count(scope: MemoryScope?) async throws -> Int
    /// 重建记忆全文索引，返回索引条数
    @discardableResult
    func rebuildIndex() async throws -> Int
}

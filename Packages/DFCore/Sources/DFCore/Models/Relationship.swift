import Foundation

// MARK: - 关系档案（W6C / 决策 31、A-14）

/// 关系阶段：由证据驱动，阶段变化属"重大关系变化"，必须用户确认后才生效。
public enum RelationshipStage: String, CaseIterable, Codable, Sendable {
    /// 尚未确认任何阶段（迁移与首次启动的默认值，不可作为提案目标）
    case unset
    /// 初识
    case acquaintance
    /// 熟悉
    case familiar
    /// 亲近
    case close
    /// 稳定
    case stable

    public var displayName: String {
        switch self {
        case .unset: return "未设定"
        case .acquaintance: return "初识"
        case .familiar: return "熟悉"
        case .close: return "亲近"
        case .stable: return "稳定"
        }
    }

    /// 可被提案/确认的阶段（排除 `unset`）
    public static var selectable: [RelationshipStage] {
        allCases.filter { $0 != .unset }
    }

    public static func parse(_ raw: String) -> RelationshipStage? {
        RelationshipStage(rawValue: raw)
    }
}

/// 关系档案：单份关系的主记录。只有用户显式写入才会建行，迁移不预置。
public struct RelationshipProfile: Sendable, Equatable {
    public var id: String
    public var partnerName: String
    public var stage: RelationshipStage
    public var stageSince: Int64?
    public var closeness: Double
    public var summary: String
    public var evidenceJSON: String
    public var confirmedBy: String?
    public var confirmedAt: Int64?
    public var updatedAt: Int64

    public init(
        id: String,
        partnerName: String,
        stage: RelationshipStage,
        stageSince: Int64?,
        closeness: Double,
        summary: String,
        evidenceJSON: String,
        confirmedBy: String?,
        confirmedAt: Int64?,
        updatedAt: Int64
    ) {
        self.id = id
        self.partnerName = partnerName
        self.stage = stage
        self.stageSince = stageSince
        self.closeness = closeness
        self.summary = summary
        self.evidenceJSON = evidenceJSON
        self.confirmedBy = confirmedBy
        self.confirmedAt = confirmedAt
        self.updatedAt = updatedAt
    }

    /// 未落库时的内存默认值：阶段 `unset`、亲密度 0.5
    public static func defaultValue(id: String, at millis: Int64) -> RelationshipProfile {
        RelationshipProfile(
            id: id,
            partnerName: "",
            stage: .unset,
            stageSince: nil,
            closeness: 0.5,
            summary: "",
            evidenceJSON: "[]",
            confirmedBy: nil,
            confirmedAt: nil,
            updatedAt: millis
        )
    }
}

// MARK: - 阶段变更历史

public enum RelationshipStageChangeStatus: String, Sendable {
    case pending
    case approved
    case rejected
}

/// 阶段变更记录：模型只能提案（`pending`），用户确认后才改档案。
public struct RelationshipStageChange: Sendable, Equatable, Identifiable {
    public var id: String
    public var fromStage: RelationshipStage
    public var toStage: RelationshipStage
    public var reason: String
    public var evidenceJSON: String
    /// 提案方：`ai` / `user`
    public var decidedBy: String
    public var status: RelationshipStageChangeStatus
    public var memoryID: String?
    public var createdAt: Int64
    public var resolvedAt: Int64?

    public init(
        id: String,
        fromStage: RelationshipStage,
        toStage: RelationshipStage,
        reason: String,
        evidenceJSON: String,
        decidedBy: String,
        status: RelationshipStageChangeStatus,
        memoryID: String?,
        createdAt: Int64,
        resolvedAt: Int64?
    ) {
        self.id = id
        self.fromStage = fromStage
        self.toStage = toStage
        self.reason = reason
        self.evidenceJSON = evidenceJSON
        self.decidedBy = decidedBy
        self.status = status
        self.memoryID = memoryID
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }
}

// MARK: - 共同经历与重要转折

public enum RelationshipMilestoneKind: String, CaseIterable, Sendable {
    /// 共同经历
    case sharedExperience = "shared_experience"
    /// 重要转折
    case turningPoint = "turning_point"
    /// 纪念日
    case anniversary
    /// 其他
    case other

    public var displayName: String {
        switch self {
        case .sharedExperience: return "共同经历"
        case .turningPoint: return "重要转折"
        case .anniversary: return "纪念日"
        case .other: return "其他"
        }
    }
}

/// 时间精度：不确定的时刻不得伪装成精确时间
public enum RelationshipTimePrecision: String, CaseIterable, Sendable {
    case exact
    case day
    case month
    case year
}

/// 来源：禁止把模型推断写成真实经历
public enum RelationshipSourceKind: String, CaseIterable, Sendable {
    /// 真实互动
    case realInteraction = "real_interaction"
    /// 用户确认
    case userConfirmed = "user_confirmed"
    /// 迁移导入
    case imported = "import"

    public var displayName: String {
        switch self {
        case .realInteraction: return "真实互动"
        case .userConfirmed: return "用户确认"
        case .imported: return "迁移导入"
        }
    }
}

public struct RelationshipMilestoneDraft: Sendable, Equatable {
    public var kind: RelationshipMilestoneKind
    public var title: String
    public var summary: String
    public var occurredAt: Int64
    public var timePrecision: RelationshipTimePrecision
    public var importance: String
    public var memoryID: String?
    public var episodeID: String?
    public var sourceKind: RelationshipSourceKind

    public init(
        kind: RelationshipMilestoneKind,
        title: String,
        summary: String = "",
        occurredAt: Int64,
        timePrecision: RelationshipTimePrecision = .day,
        importance: String = "normal",
        memoryID: String? = nil,
        episodeID: String? = nil,
        sourceKind: RelationshipSourceKind = .userConfirmed
    ) {
        self.kind = kind
        self.title = title
        self.summary = summary
        self.occurredAt = occurredAt
        self.timePrecision = timePrecision
        self.importance = importance
        self.memoryID = memoryID
        self.episodeID = episodeID
        self.sourceKind = sourceKind
    }
}

public struct RelationshipMilestone: Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: RelationshipMilestoneKind
    public var title: String
    public var summary: String
    public var occurredAt: Int64
    public var timePrecision: RelationshipTimePrecision
    public var importance: String
    public var memoryID: String?
    public var episodeID: String?
    public var sourceKind: RelationshipSourceKind
    public var status: String
    public var createdAt: Int64
    public var updatedAt: Int64

    public init(
        id: String,
        kind: RelationshipMilestoneKind,
        title: String,
        summary: String,
        occurredAt: Int64,
        timePrecision: RelationshipTimePrecision,
        importance: String,
        memoryID: String?,
        episodeID: String?,
        sourceKind: RelationshipSourceKind,
        status: String,
        createdAt: Int64,
        updatedAt: Int64
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.summary = summary
        self.occurredAt = occurredAt
        self.timePrecision = timePrecision
        self.importance = importance
        self.memoryID = memoryID
        self.episodeID = episodeID
        self.sourceKind = sourceKind
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - 错误

public enum RelationshipError: Error, Equatable, CustomStringConvertible {
    case invalidStage(String)
    case sameStage(String)
    case reasonRequired
    case evidenceInvalid
    case invalidDecisionMaker(String)
    case confirmationRequiresUser(String)
    case changeNotFound(String)
    case changeResolved(String)
    /// 提案创建后档案阶段已被改动，必须重新提案
    case staleChange(from: RelationshipStage, current: RelationshipStage)
    case memoryNotFound(String)
    case episodeNotFound(String)
    case invalidMilestone(String)
    case invalidPartnerName
    case invalidCloseness(Double)
    case emptyUpdate

    public var description: String {
        switch self {
        case .invalidStage(let raw): return "未知的关系阶段：\(raw)"
        case .sameStage(let stage): return "目标阶段与当前阶段相同：\(stage)"
        case .reasonRequired: return "阶段变更必须写明理由"
        case .evidenceInvalid: return "证据必须是 JSON 数组"
        case .invalidDecisionMaker(let actor): return "不允许的决策方：\(actor)"
        case .confirmationRequiresUser(let actor):
            return "关系阶段只能由用户确认，当前决策方为：\(actor)"
        case .changeNotFound(let id): return "阶段变更记录不存在：\(id)"
        case .changeResolved(let status): return "阶段变更已处理：\(status)"
        case .staleChange(let from, let current):
            return "提案基于阶段「\(from.displayName)」，当前已是「\(current.displayName)」，请重新提案"
        case .memoryNotFound(let id): return "关联记忆不存在：\(id)"
        case .episodeNotFound(let id): return "关联经历不存在：\(id)"
        case .invalidMilestone(let reason): return "里程碑内容不合法：\(reason)"
        case .invalidPartnerName: return "对方昵称不能为空"
        case .invalidCloseness(let value): return "亲密度必须在 0–1 之间：\(value)"
        case .emptyUpdate: return "没有任何要更新的字段"
        }
    }
}

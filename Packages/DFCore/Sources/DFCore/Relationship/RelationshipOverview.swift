import Foundation

/// D31：关系回顾的展示纯逻辑。
///
/// 数据仍来自 `RelationshipService`（档案 / 阶段历史 / 里程碑），
/// 这里只负责按「五类视图」分组、排序与格式化文案，
/// 避免 App 层各自再实现一遍日期与状态规则。
///
/// 硬规则：
/// - 时间精度不得伪装：`year` 精度只显示年份，`month` 只显示年月；
/// - 关系数据不凭空生成：没有记录时给出空态提示，不补默认内容；
/// - 排序固定：里程碑按发生时间新 → 旧，阶段历史按创建时间新 → 旧。
public enum RelationshipViewSection: String, CaseIterable, Sendable {
    case overview
    case stageHistory
    case sharedExperience
    case turningPoint
    case anniversary

    public var title: String {
        switch self {
        case .overview: return "关系概览"
        case .stageHistory: return "阶段历程"
        case .sharedExperience: return "共同经历"
        case .turningPoint: return "重要转折"
        case .anniversary: return "纪念日"
        }
    }

    /// 与里程碑类型的映射（概览与阶段历程不对应里程碑）
    public var milestoneKind: RelationshipMilestoneKind? {
        switch self {
        case .overview, .stageHistory: return nil
        case .sharedExperience: return .sharedExperience
        case .turningPoint: return .turningPoint
        case .anniversary: return .anniversary
        }
    }
}

/// 里程碑在列表中的展示形态
public struct RelationshipTimelineEntry: Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: RelationshipMilestoneKind
    public var title: String
    public var summary: String
    /// 按精度格式化后的时间（不伪装精度）
    public var dateText: String
    public var importanceText: String
    public var sourceText: String
    /// 是否为重要里程碑（`high`），用于列表高亮
    public var isHighlighted: Bool

    public init(
        id: String,
        kind: RelationshipMilestoneKind,
        title: String,
        summary: String,
        dateText: String,
        importanceText: String,
        sourceText: String,
        isHighlighted: Bool
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.summary = summary
        self.dateText = dateText
        self.importanceText = importanceText
        self.sourceText = sourceText
        self.isHighlighted = isHighlighted
    }
}

/// 阶段变更在列表中的展示形态
public struct RelationshipStageEntry: Sendable, Equatable, Identifiable {
    public var id: String
    public var fromText: String
    public var toText: String
    public var reason: String
    public var statusText: String
    public var proposerText: String
    public var timeText: String
    public var isPending: Bool

    public init(
        id: String,
        fromText: String,
        toText: String,
        reason: String,
        statusText: String,
        proposerText: String,
        timeText: String,
        isPending: Bool
    ) {
        self.id = id
        self.fromText = fromText
        self.toText = toText
        self.reason = reason
        self.statusText = statusText
        self.proposerText = proposerText
        self.timeText = timeText
        self.isPending = isPending
    }
}

/// 关系回顾的完整展示模型
public struct RelationshipOverview: Sendable, Equatable {
    public var partnerNameText: String
    public var stageText: String
    public var stageSinceText: String
    public var closenessText: String
    /// 夹取到 0–1 的亲密度，供进度条直接使用
    public var closeness: Double
    public var summaryText: String
    /// 阶段是否仍未设定（界面据此提示"等待你确认"）
    public var isStageUnset: Bool
    public var sharedExperience: [RelationshipTimelineEntry]
    public var turningPoint: [RelationshipTimelineEntry]
    public var anniversary: [RelationshipTimelineEntry]
    /// `other` 类型不单独成视图，归入概览下的"其他记录"
    public var otherMilestones: [RelationshipTimelineEntry]
    public var stageHistory: [RelationshipStageEntry]
    public var pendingProposalCount: Int
    public var totalMilestones: Int
    public var hasAnyContent: Bool

    public init(
        partnerNameText: String,
        stageText: String,
        stageSinceText: String,
        closenessText: String,
        closeness: Double,
        summaryText: String,
        isStageUnset: Bool,
        sharedExperience: [RelationshipTimelineEntry],
        turningPoint: [RelationshipTimelineEntry],
        anniversary: [RelationshipTimelineEntry],
        otherMilestones: [RelationshipTimelineEntry],
        stageHistory: [RelationshipStageEntry],
        pendingProposalCount: Int,
        totalMilestones: Int,
        hasAnyContent: Bool
    ) {
        self.partnerNameText = partnerNameText
        self.stageText = stageText
        self.stageSinceText = stageSinceText
        self.closenessText = closenessText
        self.closeness = closeness
        self.summaryText = summaryText
        self.isStageUnset = isStageUnset
        self.sharedExperience = sharedExperience
        self.turningPoint = turningPoint
        self.anniversary = anniversary
        self.otherMilestones = otherMilestones
        self.stageHistory = stageHistory
        self.pendingProposalCount = pendingProposalCount
        self.totalMilestones = totalMilestones
        self.hasAnyContent = hasAnyContent
    }

    public func milestones(in section: RelationshipViewSection) -> [RelationshipTimelineEntry] {
        switch section {
        case .overview, .stageHistory: return []
        case .sharedExperience: return sharedExperience
        case .turningPoint: return turningPoint
        case .anniversary: return anniversary
        }
    }

    public func count(in section: RelationshipViewSection) -> Int {
        switch section {
        case .overview: return totalMilestones
        case .stageHistory: return stageHistory.count
        case .sharedExperience: return sharedExperience.count
        case .turningPoint: return turningPoint.count
        case .anniversary: return anniversary.count
        }
    }

    /// 某一类视图为空时的提示（不含概览）
    public func emptyHint(in section: RelationshipViewSection) -> String {
        switch section {
        case .overview:
            return hasAnyContent
                ? "关系记录都在本地，只有你确认后才写入"
                : "还没有关系记录。确认她的阶段提案或添加里程碑后，这里会出现"
        case .stageHistory:
            return "还没有阶段变更记录。阶段只能由你确认后才生效"
        case .sharedExperience, .turningPoint, .anniversary:
            return "还没有\(section.title)记录"
        }
    }

    /// 汇总：把数据库三份原始记录整理成五类视图所需的展示数据
    public static func compose(
        profile: RelationshipProfile,
        milestones: [RelationshipMilestone],
        stageChanges: [RelationshipStageChange],
        timeZone: TimeZone = .current
    ) -> RelationshipOverview {
        // 先按发生时间新 → 旧；同一时刻用 id 稳定排序，避免刷新抖动
        let sorted = milestones
            .sorted { lhs, rhs in
                if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt > rhs.occurredAt }
                return lhs.id > rhs.id
            }
            .map { milestone -> RelationshipTimelineEntry in
                RelationshipTimelineEntry(
                    id: milestone.id,
                    kind: milestone.kind,
                    title: milestone.title,
                    summary: milestone.summary,
                    dateText: RelationshipDateText.text(
                        millis: milestone.occurredAt,
                        precision: milestone.timePrecision,
                        timeZone: timeZone
                    ),
                    importanceText: RelationshipOverview.importanceText(milestone.importance),
                    sourceText: milestone.sourceKind.displayName,
                    isHighlighted: milestone.importance == "high"
                )
            }

        let shared = sorted.filter { $0.kind == .sharedExperience }
        let turning = sorted.filter { $0.kind == .turningPoint }
        let anniversary = sorted.filter { $0.kind == .anniversary }
        let others = sorted.filter { $0.kind == .other }

        let stageEntries = stageChanges
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id > rhs.id
            }
            .map { change in
                RelationshipStageEntry(
                    id: change.id,
                    fromText: change.fromStage.displayName,
                    toText: change.toStage.displayName,
                    reason: change.reason,
                    statusText: RelationshipOverview.statusText(change.status),
                    proposerText: RelationshipOverview.proposerText(change.decidedBy),
                    timeText: RelationshipDateText.text(
                        millis: change.createdAt,
                        precision: .exact,
                        timeZone: timeZone
                    ),
                    isPending: change.status == .pending
                )
            }

        let pending = stageChanges.filter { $0.status == .pending }.count
        let partnerName = profile.partnerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = profile.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContent = !milestones.isEmpty
            || !stageChanges.isEmpty
            || !partnerName.isEmpty
            || !summary.isEmpty
            || profile.stage != .unset

        return RelationshipOverview(
            partnerNameText: partnerName.isEmpty ? "还没有设置昵称" : partnerName,
            stageText: profile.stage.displayName,
            stageSinceText: profile.stageSince.map {
                RelationshipDateText.text(millis: $0, precision: .day, timeZone: timeZone)
            } ?? "—",
            closenessText: closenessText(profile.closeness),
            closeness: clampedCloseness(profile.closeness),
            summaryText: summary.isEmpty ? "还没有写下你们的关系说明" : summary,
            isStageUnset: profile.stage == .unset,
            sharedExperience: shared,
            turningPoint: turning,
            anniversary: anniversary,
            otherMilestones: others,
            stageHistory: stageEntries,
            pendingProposalCount: pending,
            totalMilestones: milestones.count,
            hasAnyContent: hasContent
        )
    }

    // MARK: - 文案

    /// 亲密度夹取到 0–1，NaN 视为 0
    public static func clampedCloseness(_ value: Double) -> Double {
        guard !value.isNaN else { return 0 }
        return min(max(value, 0), 1)
    }

    /// 亲密度百分比：夹取到 0–1，NaN 视为 0
    public static func closenessText(_ value: Double) -> String {
        let clamped = clampedCloseness(value)
        return "\(Int((clamped * 100).rounded()))%"
    }

    public static func importanceText(_ raw: String) -> String {
        switch raw {
        case "high": return "重要"
        case "low": return "次要"
        default: return "一般"
        }
    }

    public static func statusText(_ status: RelationshipStageChangeStatus) -> String {
        switch status {
        case .pending: return "待你确认"
        case .approved: return "已确认"
        case .rejected: return "已驳回"
        }
    }

    public static func proposerText(_ decidedBy: String) -> String {
        switch decidedBy {
        case "ai": return "她提出"
        case "user": return "你提出"
        default: return decidedBy
        }
    }
}

/// 关系时间文案：严格按记录精度输出，不补足未记录的部分
public enum RelationshipDateText {
    public static func text(
        millis: Int64,
        precision: RelationshipTimePrecision,
        timeZone: TimeZone = .current
    ) -> String {
        guard millis > 0 else { return "时间未知" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = Date(timeIntervalSince1970: Double(millis) / 1000)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let year = parts.year ?? 0
        let month = parts.month ?? 1
        let day = parts.day ?? 1
        switch precision {
        case .exact:
            let hour = parts.hour ?? 0
            let minute = parts.minute ?? 0
            return String(format: "%04d-%02d-%02d %02d:%02d", year, month, day, hour, minute)
        case .day:
            return String(format: "%04d-%02d-%02d", year, month, day)
        case .month:
            return "\(year)年\(month)月"
        case .year:
            return "\(year)年"
        }
    }
}

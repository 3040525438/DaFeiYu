import Foundation

// MARK: - 七层记忆加工（W8 / L1–L7）

/// 七层是**加工深度**，不是七个数据库（见 04 文档）。
/// 其中只有 episodic / semantic / procedural / reflective 落在 `memories` 表内；
/// L1 原始消息、L6 图谱、L7 工作记忆各自有专用承载。
public enum MemoryLayer: String, Codable, Sendable, CaseIterable {
    /// L1 原始经历：messages / attachments，只读，不可改写
    case raw = "raw"
    /// L2 情景记忆
    case episodic = "episodic"
    /// L3 语义记忆
    case semantic = "semantic"
    /// L4 程序记忆
    case procedural = "procedural"
    /// L5 反思记忆
    case reflective = "reflective"
    /// L6 时序知识图谱
    case graph = "graph"
    /// L7 动态工作记忆
    case working = "working"

    public var level: Int {
        switch self {
        case .raw: return 1
        case .episodic: return 2
        case .semantic: return 3
        case .procedural: return 4
        case .reflective: return 5
        case .graph: return 6
        case .working: return 7
        }
    }

    public var displayName: String {
        switch self {
        case .raw: return "L1 原始经历"
        case .episodic: return "L2 情景记忆"
        case .semantic: return "L3 语义记忆"
        case .procedural: return "L4 程序记忆"
        case .reflective: return "L5 反思记忆"
        case .graph: return "L6 时序知识图谱"
        case .working: return "L7 动态工作记忆"
        }
    }

    /// 是否以 `memories` 行承载
    public var persistsInMemories: Bool {
        switch self {
        case .episodic, .semantic, .procedural, .reflective: return true
        case .raw, .graph, .working: return false
        }
    }

    /// 检索权重（04 文档第 8 节）
    public var retrievalWeight: Double {
        switch self {
        case .raw: return 0
        case .episodic: return 0.90
        case .semantic: return 1.00
        case .procedural: return 0
        case .reflective: return 0.80
        case .graph: return 0.85
        case .working: return 0
        }
    }

    /// 衰减时间常数（天）
    public var decayTauDays: Double {
        switch self {
        case .raw: return 0
        case .episodic: return 730
        case .semantic: return 3650
        case .procedural: return 0
        case .reflective: return 365
        case .graph: return 0
        case .working: return 0
        }
    }

    /// 该层允许的归属（04 文档第 3 节）
    public var allowedScopes: Set<MemoryScope> {
        switch self {
        case .raw:
            // 用户原话属于共同经历，L1 只归 shared
            return [.shared]
        case .episodic, .semantic, .procedural, .reflective, .graph, .working:
            return [.user, .shared, .selfScope]
        }
    }
}

// MARK: - 三主体治理

public enum MemoryGovernanceError: Error, Equatable, CustomStringConvertible {
    case invalidScopeForLayer(scope: String, layer: String)

    public var description: String {
        switch self {
        case .invalidScopeForLayer(let scope, let layer):
            return "层级 \(layer) 不允许归属 \(scope)"
        }
    }
}

/// 一句话的主语决定它属于哪套记忆（04 文档第 3 节："这句话的主语是谁，记忆就属于谁"）。
public enum MemorySubject: String, Codable, Sendable, CaseIterable {
    case user
    case both
    case aiSelf = "self"
    case unknown
}

public enum MemoryGovernance {
    /// 涉及关系/底线的类别，写入必须走用户确认（D12 / D18）
    public static let criticalCategories: Set<String> = [
        "relationship", "boundary", "promise", "identity", "value", "emotion_pattern"
    ]

    /// 主语 → 归属；无法判断时落到 shared 且**必须**标记待确认，禁止静默归类
    public static func resolveScope(subject: MemorySubject) -> (scope: MemoryScope, needsConfirmation: Bool) {
        switch subject {
        case .user: return (.user, false)
        case .both: return (.shared, false)
        case .aiSelf: return (.selfScope, false)
        case .unknown: return (.shared, true)
        }
    }

    public static func validate(scope: MemoryScope, layer: MemoryLayer) throws {
        guard layer.allowedScopes.contains(scope) else {
            throw MemoryGovernanceError.invalidScopeForLayer(scope: scope.rawValue, layer: layer.rawValue)
        }
    }

    public static func requiresConfirmation(category: String) -> Bool {
        criticalCategories.contains(normalizeCategory(category))
    }

    public static func normalizeCategory(_ category: String) -> String {
        category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - 抽取候选

public struct MemoryCandidate: Sendable, Equatable {
    public var scope: MemoryScope
    public var layer: MemoryLayer
    public var category: String
    public var title: String
    public var content: String
    /// 必须能在本轮原文中定位的摘录（防编造第一道闸）
    public var evidenceQuote: String
    public var importance: Double
    public var confidence: Double
    public var epistemicStatus: String
    public var sourceKind: String
    /// 归属无法由主语判断时为 true，写入必须转为确认提案
    public var scopeNeedsConfirmation: Bool
    public var dedupeKey: String?

    public init(
        scope: MemoryScope = .shared,
        layer: MemoryLayer = .semantic,
        category: String = "fact",
        title: String,
        content: String,
        evidenceQuote: String,
        importance: Double = 0.5,
        confidence: Double = 0.6,
        epistemicStatus: String = "observed",
        sourceKind: String = "real_interaction",
        scopeNeedsConfirmation: Bool = false,
        dedupeKey: String? = nil
    ) {
        self.scope = scope
        self.layer = layer
        self.category = category
        self.title = title
        self.content = content
        self.evidenceQuote = evidenceQuote
        self.importance = importance
        self.confidence = confidence
        self.epistemicStatus = epistemicStatus
        self.sourceKind = sourceKind
        self.scopeNeedsConfirmation = scopeNeedsConfirmation
        self.dedupeKey = dedupeKey
    }
}

public struct MemoryScreenRejection: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable {
        case emptyContent
        case evidenceNotLocated
        case invalidScopeForLayer
        case duplicateInBatch
        case budgetExceeded
    }

    public var title: String
    public var reason: Reason

    public init(title: String, reason: Reason) {
        self.title = title
        self.reason = reason
    }
}

public struct MemoryScreenResult: Sendable, Equatable {
    public var accepted: [MemoryCandidate]
    public var rejections: [MemoryScreenRejection]
    public var droppedByBudget: Int

    public init(
        accepted: [MemoryCandidate] = [],
        rejections: [MemoryScreenRejection] = [],
        droppedByBudget: Int = 0
    ) {
        self.accepted = accepted
        self.rejections = rejections
        self.droppedByBudget = droppedByBudget
    }
}

public enum MemoryWriteRoute: String, Sendable, Equatable {
    /// 直接写 memories
    case direct
    /// 写 proposals，等用户确认
    case confirm
}

// MARK: - 抽取策略（纯逻辑）

public struct MemoryExtractionPolicy: Sendable, Equatable {
    /// 单轮最多产出候选数（05 文档硬规则 2）
    public var maxCandidatesPerTurn: Int
    /// 重要度达到该阈值必须确认（05 文档 1 节）
    public var confirmThreshold: Double
    /// 批内相似度达到该阈值视为重复
    public var dedupeSimilarityThreshold: Double
    /// 证据高相似兜底阈值（子串找不到时的第二判据）
    public var evidenceSimilarityFloor: Double

    public init(
        maxCandidatesPerTurn: Int = 8,
        confirmThreshold: Double = 0.7,
        dedupeSimilarityThreshold: Double = 0.82,
        evidenceSimilarityFloor: Double = 0.72
    ) {
        self.maxCandidatesPerTurn = maxCandidatesPerTurn
        self.confirmThreshold = confirmThreshold
        self.dedupeSimilarityThreshold = dedupeSimilarityThreshold
        self.evidenceSimilarityFloor = evidenceSimilarityFloor
    }

    public static let `default` = MemoryExtractionPolicy()

    // MARK: 筛选

    /// 一次筛掉：空内容、证据无法定位、层级/归属非法、批内重复，并截断到单轮上限。
    /// - Parameter remainingBudget: 当日剩余抽取预算；`nil` 表示不限
    public func screen(
        _ candidates: [MemoryCandidate],
        sourceText: String,
        remainingBudget: Int? = nil
    ) -> MemoryScreenResult {
        var accepted: [MemoryCandidate] = []
        var rejections: [MemoryScreenRejection] = []
        var droppedByBudget = 0

        let budget = remainingBudget ?? Int.max

        for candidate in candidates {
            let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = candidate.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                rejections.append(.init(title: title, reason: .emptyContent))
                continue
            }
            guard locate(quote: candidate.evidenceQuote, in: sourceText) else {
                rejections.append(.init(title: title, reason: .evidenceNotLocated))
                continue
            }
            do {
                try MemoryGovernance.validate(scope: candidate.scope, layer: candidate.layer)
            } catch {
                rejections.append(.init(title: title, reason: .invalidScopeForLayer))
                continue
            }
            if accepted.contains(where: { isDuplicate(candidate, $0) }) {
                rejections.append(.init(title: title, reason: .duplicateInBatch))
                continue
            }
            if accepted.count >= maxCandidatesPerTurn {
                droppedByBudget += 1
                continue
            }
            if accepted.count >= budget {
                droppedByBudget += 1
                continue
            }
            accepted.append(candidate)
        }

        return MemoryScreenResult(
            accepted: accepted,
            rejections: rejections,
            droppedByBudget: droppedByBudget
        )
    }

    public func isDuplicate(_ lhs: MemoryCandidate, _ rhs: MemoryCandidate) -> Bool {
        guard lhs.scope == rhs.scope, lhs.layer == rhs.layer else { return false }
        guard MemoryGovernance.normalizeCategory(lhs.category) == MemoryGovernance.normalizeCategory(rhs.category) else {
            return false
        }
        if let left = lhs.dedupeKey, let right = rhs.dedupeKey, left == right { return true }
        return similarity(lhs.content, rhs.content) >= dedupeSimilarityThreshold
    }

    // MARK: 证据定位

    /// 摘录必须能在原文中定位：先做归一化子串匹配，再退到 bigram 相似度。
    public func locate(quote: String, in source: String) -> Bool {
        let normalizedQuote = Self.normalize(quote)
        let normalizedSource = Self.normalize(source)
        guard normalizedQuote.count >= 2, !normalizedSource.isEmpty else { return false }
        if normalizedSource.contains(normalizedQuote) { return true }
        return similarity(quote, source) >= evidenceSimilarityFloor
    }

    // MARK: 相似度

    /// bigram Jaccard 相似度（0…1）
    public func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Self.bigrams(lhs)
        let right = Self.bigrams(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let intersection = left.intersection(right).count
        let union = left.union(right).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    // MARK: 去重键

    public func normalizedDedupeKey(for candidate: MemoryCandidate) -> String {
        let category = MemoryGovernance.normalizeCategory(candidate.category)
        let body = Self.normalize(candidate.content)
        let digest = String(SHA256.hash(body).prefix(24))
        return "\(candidate.scope.rawValue)|\(candidate.layer.rawValue)|\(category)|\(digest)"
    }

    // MARK: 路由

    /// 重要度高、涉及关系/底线、归属待确认 → 必须走确认提案
    public func route(for candidate: MemoryCandidate) -> MemoryWriteRoute {
        if candidate.importance >= confirmThreshold { return .confirm }
        if MemoryGovernance.requiresConfirmation(category: candidate.category) { return .confirm }
        if candidate.scopeNeedsConfirmation { return .confirm }
        return .direct
    }

    // MARK: 内部

    /// 归一化：去掉空白与标点，保留字母/数字/汉字并转小写
    static func normalize(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text.lowercased() where character.isLetter || character.isNumber {
            result.append(character)
        }
        return result
    }

    static func bigrams(_ text: String) -> Set<String> {
        let characters = Array(normalize(text))
        guard characters.count > 1 else {
            return characters.isEmpty ? [] : [String(characters)]
        }
        var tokens = Set<String>()
        for index in 0..<(characters.count - 1) {
            tokens.insert(String(characters[index...index + 1]))
        }
        return tokens
    }
}

// MARK: - 冲突检测与合并计划

public struct MemoryFactSnapshot: Sendable, Equatable {
    public var id: String
    public var subject: String
    public var attribute: String
    public var value: String
    public var validFrom: Int64?
    public var validTo: Int64?

    public init(
        id: String,
        subject: String,
        attribute: String,
        value: String,
        validFrom: Int64? = nil,
        validTo: Int64? = nil
    ) {
        self.id = id
        self.subject = subject
        self.attribute = attribute
        self.value = value
        self.validFrom = validFrom
        self.validTo = validTo
    }
}

public enum MemoryConflictKind: String, Sendable, Equatable {
    case none
    /// 值随时间变化：两条可并存，靠有效期区分
    case timeChange
    /// 无法判定谁对：双方 disputed，等用户裁决
    case dispute
}

public enum MemoryConflictDetector {
    public static func conflict(between lhs: MemoryFactSnapshot, and rhs: MemoryFactSnapshot) -> MemoryConflictKind {
        guard MemoryExtractionPolicy.normalize(lhs.subject) == MemoryExtractionPolicy.normalize(rhs.subject),
              MemoryExtractionPolicy.normalize(lhs.attribute) == MemoryExtractionPolicy.normalize(rhs.attribute) else {
            return .none
        }
        guard MemoryExtractionPolicy.normalize(lhs.value) != MemoryExtractionPolicy.normalize(rhs.value) else {
            return .none
        }
        if let leftStart = lhs.validFrom, let rightStart = rhs.validFrom, leftStart != rightStart {
            return .timeChange
        }
        return .dispute
    }
}

public struct MemoryConsolidationItem: Sendable, Equatable {
    public var id: String
    public var scope: MemoryScope
    public var layer: String
    public var category: String
    public var title: String
    public var content: String
    public var salience: Double
    public var lastRecalledAt: Int64?
    public var firstSeenAt: Int64

    public init(
        id: String,
        scope: MemoryScope,
        layer: String,
        category: String,
        title: String,
        content: String,
        salience: Double,
        lastRecalledAt: Int64?,
        firstSeenAt: Int64
    ) {
        self.id = id
        self.scope = scope
        self.layer = layer
        self.category = category
        self.title = title
        self.content = content
        self.salience = salience
        self.lastRecalledAt = lastRecalledAt
        self.firstSeenAt = firstSeenAt
    }
}

public enum MemoryConsolidationPlanner {
    /// 同 scope + 同 layer + 同 category 内按相似度聚类。
    /// 返回每组 id，**第一个是幸存者**（信息量最大：正文最长，等长取 id 最小）。
    public static func duplicateGroups(
        _ items: [MemoryConsolidationItem],
        threshold: Double = 0.90,
        similarity: (String, String) -> Double
    ) -> [[String]] {
        var remaining = items.sorted { $0.id < $1.id }
        var groups: [[String]] = []

        while let seed = remaining.first {
            remaining.removeFirst()
            var group = [seed]
            remaining.removeAll { candidate in
                guard candidate.scope == seed.scope,
                      candidate.layer == seed.layer,
                      MemoryGovernance.normalizeCategory(candidate.category) == MemoryGovernance.normalizeCategory(seed.category) else {
                    return false
                }
                guard similarity(seed.content, candidate.content) >= threshold else { return false }
                group.append(candidate)
                return true
            }
            guard group.count > 1 else { continue }
            let survivor = group.max { lhs, rhs in
                if lhs.content.count == rhs.content.count { return lhs.id > rhs.id }
                return lhs.content.count < rhs.content.count
            }
            let ordered = [survivor] + group.filter { $0.id != survivor.id }
            groups.append(ordered.map(\.id))
        }

        return groups
    }

    /// 冷记忆归档：超过 180 天未召回且 salience < 0.3
    public static func shouldArchive(
        _ item: MemoryConsolidationItem,
        now: Int64,
        coldDays: Double = 180,
        salienceThreshold: Double = 0.3
    ) -> Bool {
        guard item.salience < salienceThreshold else { return false }
        let reference = item.lastRecalledAt ?? item.firstSeenAt
        let age = Double(now - reference) / (24 * 60 * 60 * 1000)
        return age > coldDays
    }
}

// MARK: - 反思策略

public struct ReflectionConclusion: Sendable, Equatable {
    public var content: String
    public var conclusion: String
    /// 必须引用 ≥1 条素材 ID（05 文档反思红线）
    public var evidenceRefs: [String]
    /// observed / inferred
    public var epistemicStatus: String
    /// 是否可沉淀为稳定自我记忆
    public var stable: Bool
    /// 是否涉及核心人格：只能提案，不能自动生效
    public var affectsCorePersona: Bool

    public init(
        content: String,
        conclusion: String = "",
        evidenceRefs: [String] = [],
        epistemicStatus: String = "inferred",
        stable: Bool = false,
        affectsCorePersona: Bool = false
    ) {
        self.content = content
        self.conclusion = conclusion
        self.evidenceRefs = evidenceRefs
        self.epistemicStatus = epistemicStatus
        self.stable = stable
        self.affectsCorePersona = affectsCorePersona
    }
}

public struct ReflectionPolicy: Sendable, Equatable {
    public var allowedEpistemic: Set<String>

    public init(allowedEpistemic: Set<String> = ["observed", "inferred"]) {
        self.allowedEpistemic = allowedEpistemic
    }

    public static let `default` = ReflectionPolicy()

    /// 引用校验：无有效引用或认识状态非法的一律丢弃，不硬凑。
    public func validate(
        _ conclusions: [ReflectionConclusion],
        availableRefs: Set<String>
    ) -> (accepted: [ReflectionConclusion], rejected: [ReflectionConclusion]) {
        var accepted: [ReflectionConclusion] = []
        var rejected: [ReflectionConclusion] = []

        for conclusion in conclusions {
            let content = conclusion.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let refs = conclusion.evidenceRefs.filter { availableRefs.contains($0) }
            guard !content.isEmpty,
                  !refs.isEmpty,
                  allowedEpistemic.contains(conclusion.epistemicStatus) else {
                rejected.append(conclusion)
                continue
            }
            var normalized = conclusion
            normalized.content = content
            normalized.evidenceRefs = refs
            accepted.append(normalized)
        }
        return (accepted, rejected)
    }
}

// MARK: - L7 动态工作记忆

public enum WorkingMemoryItemKind: String, Codable, Sendable, CaseIterable {
    case currentUserMessage = "current_user_message"
    case pinnedFact = "pinned_fact"
    case openTopic = "open_topic"
    case retrievedMemory = "retrieved_memory"
    case recentTurn = "recent_turn"

    /// 预算裁剪优先级：数字越小越先装载（05 文档 6.2 节）
    public var priority: Int {
        switch self {
        case .currentUserMessage: return 1
        case .pinnedFact: return 2
        case .openTopic: return 3
        case .retrievedMemory: return 4
        case .recentTurn: return 5
        }
    }
}

public struct WorkingMemoryItem: Codable, Sendable, Equatable {
    public var id: String
    public var kind: WorkingMemoryItemKind
    public var text: String
    public var estimatedTokens: Int
    public var scope: MemoryScope?
    public var sourceRef: String?

    public init(
        id: String,
        kind: WorkingMemoryItemKind,
        text: String,
        estimatedTokens: Int? = nil,
        scope: MemoryScope? = nil,
        sourceRef: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.estimatedTokens = estimatedTokens ?? WorkingMemoryAssembler.estimateTokens(text)
        self.scope = scope
        self.sourceRef = sourceRef
    }
}

public struct WorkingMemoryBudget: Sendable, Equatable {
    public var maxTokens: Int

    public init(maxTokens: Int = 2400) {
        self.maxTokens = max(1, maxTokens)
    }

    public static let `default` = WorkingMemoryBudget()
}

public struct WorkingMemoryDroppedItem: Codable, Sendable, Equatable {
    public enum Reason: String, Codable, Sendable, Equatable {
        case budgetExceeded
        case duplicate
    }

    public var id: String
    public var kind: WorkingMemoryItemKind
    public var reason: Reason
    public var estimatedTokens: Int

    public init(id: String, kind: WorkingMemoryItemKind, reason: Reason, estimatedTokens: Int) {
        self.id = id
        self.kind = kind
        self.reason = reason
        self.estimatedTokens = estimatedTokens
    }
}

public struct WorkingMemoryPackage: Codable, Sendable, Equatable {
    public var conversationID: String
    public var builtAt: Int64
    public var items: [WorkingMemoryItem]
    public var dropped: [WorkingMemoryDroppedItem]
    public var estimatedTokens: Int

    public init(
        conversationID: String,
        builtAt: Int64,
        items: [WorkingMemoryItem],
        dropped: [WorkingMemoryDroppedItem],
        estimatedTokens: Int
    ) {
        self.conversationID = conversationID
        self.builtAt = builtAt
        self.items = items
        self.dropped = dropped
        self.estimatedTokens = estimatedTokens
    }
}

public enum WorkingMemoryAssembler {
    /// 轻量估算：中文按 1 字≈1 token，其余按 4 字符≈1 token
    public static func estimateTokens(_ text: String) -> Int {
        var tokens = 0
        var asciiRun = 0
        func flushASCII() {
            if asciiRun > 0 {
                tokens += (asciiRun + 3) / 4
                asciiRun = 0
            }
        }
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                asciiRun += 1
            } else {
                flushASCII()
                tokens += 1
            }
        }
        flushASCII()
        return max(tokens, 1)
    }

    /// 按优先级装载；当前用户消息永不被裁掉，被丢弃的条目全部留痕（可解释）。
    public static func assemble(
        conversationID: String,
        items: [WorkingMemoryItem],
        budget: WorkingMemoryBudget = .default,
        at millis: Int64
    ) -> WorkingMemoryPackage {
        var ordered: [WorkingMemoryItem] = []
        var dropped: [WorkingMemoryDroppedItem] = []
        var seenTexts = Set<String>()
        var usedTokens = 0

        for item in items.sorted(by: { $0.kind.priority < $1.kind.priority }) {
            let normalized = MemoryExtractionPolicy.normalize(item.text)
            guard !normalized.isEmpty else { continue }
            if seenTexts.contains(normalized) {
                dropped.append(.init(id: item.id, kind: item.kind, reason: .duplicate, estimatedTokens: item.estimatedTokens))
                continue
            }
            if item.kind != .currentUserMessage, usedTokens + item.estimatedTokens > budget.maxTokens {
                dropped.append(.init(id: item.id, kind: item.kind, reason: .budgetExceeded, estimatedTokens: item.estimatedTokens))
                continue
            }
            seenTexts.insert(normalized)
            usedTokens += item.estimatedTokens
            ordered.append(item)
        }

        return WorkingMemoryPackage(
            conversationID: conversationID,
            builtAt: millis,
            items: ordered,
            dropped: dropped,
            estimatedTokens: usedTokens
        )
    }
}

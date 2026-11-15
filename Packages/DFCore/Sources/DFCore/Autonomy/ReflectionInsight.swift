import Foundation
import CoreFoundation

// MARK: - 自主洞察（D62：主动回顾 / 记忆关联 / 值得记录 / 观点变化 / 修正建议）
//
// 借鉴边界（ADR-09）：
// - 只借鉴"闭集枚举 + 严格 Schema 校验 + 证据逐字校验 + 置信度夹取 + 待用户确认提案"这套机制；
// - 不复制 AGPL-3.0 源码，不使用 Python / FastAPI / Electron 作为 iOS 运行依赖；
// - 全部为纯函数与值类型，不读时钟、不读数据库，便于在 CI 上覆盖异常输入与边界值。
//
// 硬规则：洞察只是"提案"，绝不直接写记忆、改人格、动关系。
// 凡触及记忆 / 关系的洞察一律 `requiresUserConfirmation == true`；
// 唯一只读的是"回顾近期经历"。

/// 自主洞察的闭集类型。
///
/// 模型只能从这个闭集中取值，避免自由文本进入后续处理流程。
public enum ReflectionInsightKind: String, Sendable, Equatable, CaseIterable {
    /// 主动回顾近期经历（只读：把最近发生的事重新呈现给用户）
    case recallRecent = "recall_recent"
    /// 历史记忆关联（把当前话题与旧记忆连起来，需要用户确认）
    case memoryLink = "memory_link"
    /// 发现值得记录的经历（建议写入记忆，需要用户确认）
    case worthRecording = "worth_recording"
    /// 识别用户观点变化（建议更新旧认知，需要用户确认）
    case stanceChange = "stance_change"
    /// 主动提出记忆回顾 / 修正建议（需要用户确认）
    case correctionProposal = "correction_proposal"

    /// 是否必须经用户确认才能落地。
    ///
    /// 只有 `recallRecent` 是只读展示；其余四类都会触及记忆或关系，一律为 true。
    public var requiresUserConfirmation: Bool {
        switch self {
        case .recallRecent: return false
        case .memoryLink, .worthRecording, .stanceChange, .correctionProposal: return true
        }
    }

    /// 是否必须给出目标记忆 id。
    ///
    /// 关联与修正都指向"某一条已存在的记忆"，没有 id 就无法核对，不应进入提案列表。
    public var requiresTargetMemory: Bool {
        switch self {
        case .memoryLink, .correctionProposal: return true
        case .recallRecent, .worthRecording, .stanceChange: return false
        }
    }

    /// 中文展示名
    public var displayName: String {
        switch self {
        case .recallRecent: return "回顾近期经历"
        case .memoryLink: return "历史记忆关联"
        case .worthRecording: return "值得记录的经历"
        case .stanceChange: return "用户观点变化"
        case .correctionProposal: return "记忆修正建议"
        }
    }
}

/// 一条已通过校验的自主洞察。
///
/// 所有字段都是"已经过校验与夹取"的安全值：
/// - `summary` 已去首尾空白并截断到上限；
/// - `evidence` 每条都逐字出现在调用方提供的上下文里；
/// - `confidence` 恒在 0...1。
public struct ReflectionInsight: Sendable, Equatable {
    public var kind: ReflectionInsightKind
    public var summary: String
    /// 证据片段：逐字来自上下文，不允许模型编造
    public var evidence: [String]
    /// 置信度，0...1
    public var confidence: Double
    /// 关联 / 修正所指向的记忆 id
    public var targetMemoryID: String?

    public init(
        kind: ReflectionInsightKind,
        summary: String,
        evidence: [String],
        confidence: Double,
        targetMemoryID: String? = nil
    ) {
        self.kind = kind
        self.summary = String(
            summary.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(ReflectionInsightPolicy.maxSummaryLength)
        )
        self.evidence = Array(
            evidence
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(ReflectionInsightPolicy.maxEvidenceCount)
        )
        self.confidence = ReflectionInsightPolicy.clampConfidence(confidence)
        let trimmedTarget = targetMemoryID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.targetMemoryID = (trimmedTarget?.isEmpty ?? true) ? nil : trimmedTarget
    }

    /// 是否必须经用户确认（由类型唯一决定，模型无法改写）
    public var requiresUserConfirmation: Bool { kind.requiresUserConfirmation }
}

// MARK: - 策略与校验

/// 洞察的统一规则入口：上限、夹取、证据校验、去重。
public enum ReflectionInsightPolicy {
    /// 单次最多采纳的洞察条数（超出截断，不整体拒绝）
    public static let maxInsights = 5
    /// 单条洞察摘要长度上限
    public static let maxSummaryLength = 280
    /// 单条洞察证据条数上限
    public static let maxEvidenceCount = 4
    /// 单条证据长度上限；超长证据一律丢弃（保持"逐字"可比对）
    public static let maxEvidenceLength = 200
    /// 置信度低于该值的洞察不进入提案列表
    public static let minConfidence = 0.3

    /// 把置信度夹到 0...1；NaN / 无穷返回 0。
    public static func clampConfidence(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    /// 证据是否逐字出现在上下文中。
    ///
    /// 只忽略空白（换行 / 连续空格 / 行首缩进），不做模糊匹配：
    /// 模型改写过的句子必须被丢弃。
    public static func evidenceAppears(_ excerpt: String, in contextText: String) -> Bool {
        let needle = squashed(excerpt)
        guard !needle.isEmpty else { return false }
        let haystack = squashed(contextText)
        guard !haystack.isEmpty else { return false }
        return haystack.contains(needle)
    }

    /// 过滤证据：去掉空白项、超长项、上下文中不存在的项，并去重。
    public static func filterEvidence(_ evidence: [String], against contextText: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in evidence {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= maxEvidenceLength else { continue }
            guard evidenceAppears(trimmed, in: contextText) else { continue }
            let key = normalized(trimmed)
            guard seen.insert(key).inserted else { continue }
            result.append(trimmed)
            if result.count >= maxEvidenceCount { break }
        }
        return result
    }

    /// 校验单条洞察；不合法返回 nil（丢弃，不抛错）。
    ///
    /// 丢弃条件：摘要为空、证据全部不可信、置信度低于下限、关联类缺少目标记忆 id。
    public static func sanitize(_ insight: ReflectionInsight, contextText: String) -> ReflectionInsight? {
        let summary = insight.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return nil }
        guard clampConfidence(insight.confidence) >= minConfidence else { return nil }
        if insight.kind.requiresTargetMemory, insight.targetMemoryID == nil { return nil }
        let evidence = filterEvidence(insight.evidence, against: contextText)
        guard !evidence.isEmpty else { return nil }
        var cleaned = insight
        cleaned.summary = String(summary.prefix(maxSummaryLength))
        cleaned.evidence = evidence
        return cleaned
    }

    /// 批量校验：逐条 sanitize → 去重（同类型 + 同摘要）→ 截断到上限。
    public static func sanitizeBatch(
        _ insights: [ReflectionInsight],
        contextText: String
    ) -> [ReflectionInsight] {
        var seen = Set<String>()
        var result: [ReflectionInsight] = []
        for insight in insights {
            guard let cleaned = sanitize(insight, contextText: contextText) else { continue }
            let key = "\(cleaned.kind.rawValue)|\(normalized(cleaned.summary))"
            guard seen.insert(key).inserted else { continue }
            result.append(cleaned)
            if result.count >= maxInsights { break }
        }
        return result
    }

    /// 空白归一：把任意连续空白压成单个空格，首尾去空白。
    /// 对外可见：服务层做"同类同摘要"去重时复用同一口径。
    public static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// 去掉全部空白，只用于证据逐字比对（中文没有词间空格，换行不应影响命中）
    private static func squashed(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }
}

// MARK: - 解析失败原因

/// 解析失败原因。失败时一律返回空结果，**不抛错、不崩溃**。
public enum ReflectionInsightParseFailure: String, Sendable, Equatable {
    case emptyOutput
    case notJSONObject
    case unknownKeys
    case missingKeys
    case invalidTypes
    case invalidKind
}

/// 解析结果：洞察数组 + 失败原因（nil 表示严格校验通过）。
public struct ReflectionInsightParseResult: Sendable, Equatable {
    public var insights: [ReflectionInsight]
    public var failure: ReflectionInsightParseFailure?

    public init(insights: [ReflectionInsight], failure: ReflectionInsightParseFailure?) {
        self.insights = insights
        self.failure = failure
    }

    public static func failure(_ failure: ReflectionInsightParseFailure) -> ReflectionInsightParseResult {
        ReflectionInsightParseResult(insights: [], failure: failure)
    }

    public var isStrict: Bool { failure == nil }
}

// MARK: - 严格解析器

/// 自主洞察输出的严格 JSON 解析器。
///
/// Schema（顶层只允许 `insights`；每条洞察的键集必须完全一致）：
/// ```json
/// {
///   "insights": [
///     {
///       "kind": "recall_recent|memory_link|worth_recording|stance_change|correction_proposal",
///       "summary": "string",
///       "evidence": ["逐字片段"],
///       "confidence": 0.0,
///       "target_memory_id": "string|null"
///     }
///   ]
/// }
/// ```
public enum ReflectionInsightParser {
    /// 顶层允许的键
    public static let allowedTopLevelKeys: Set<String> = ["insights"]
    /// 每条洞察允许的键
    public static let allowedItemKeys: Set<String> = [
        "kind", "summary", "evidence", "confidence", "target_memory_id"
    ]
    /// 每条洞察必须出现的键
    public static let requiredItemKeys: Set<String> = [
        "kind", "summary", "evidence", "confidence"
    ]

    /// 解析模型原始输出。任何异常都返回空结果并附上失败原因。
    public static func parse(_ raw: String) -> ReflectionInsightParseResult {
        let text = ReflectionOutputParser.stripCodeFence(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.emptyOutput) }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return .failure(.notJSONObject)
        }

        let keys = Set(dict.keys)
        guard keys.subtracting(allowedTopLevelKeys).isEmpty else {
            return .failure(.unknownKeys)
        }
        guard keys.contains("insights") else {
            return .failure(.missingKeys)
        }
        guard let items = dict["insights"] as? [Any] else {
            return .failure(.invalidTypes)
        }

        var insights: [ReflectionInsight] = []
        for element in items {
            guard let item = element as? [String: Any] else {
                return .failure(.invalidTypes)
            }
            let itemKeys = Set(item.keys)
            guard itemKeys.subtracting(allowedItemKeys).isEmpty else {
                return .failure(.unknownKeys)
            }
            guard requiredItemKeys.isSubset(of: itemKeys) else {
                return .failure(.missingKeys)
            }
            guard let kindRaw = item["kind"] as? String,
                  let kind = ReflectionInsightKind(rawValue: kindRaw) else {
                return .failure(.invalidKind)
            }
            guard let summary = item["summary"] as? String else {
                return .failure(.invalidTypes)
            }
            guard let evidenceArray = item["evidence"] as? [Any],
                  evidenceArray.allSatisfy({ $0 is String }) else {
                return .failure(.invalidTypes)
            }
            guard let confidenceNumber = numericValue(item["confidence"]) else {
                return .failure(.invalidTypes)
            }
            var target: String?
            if let rawTarget = item["target_memory_id"], !(rawTarget is NSNull) {
                guard let targetText = rawTarget as? String else {
                    return .failure(.invalidTypes)
                }
                target = targetText
            }

            insights.append(
                ReflectionInsight(
                    kind: kind,
                    summary: summary,
                    evidence: evidenceArray.compactMap { $0 as? String },
                    confidence: confidenceNumber,
                    targetMemoryID: target
                )
            )
        }
        return ReflectionInsightParseResult(insights: insights, failure: nil)
    }

    /// 只接受有限数值；JSON 布尔（`true` / `false`）不算数字。
    private static func numericValue(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite else { return nil }
        return double
    }
}

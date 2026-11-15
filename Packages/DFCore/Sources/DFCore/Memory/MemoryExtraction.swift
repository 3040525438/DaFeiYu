import Foundation

// MARK: - 记忆抽取提示词与解析（W8-3 / L2–L5 入口）

/// 一次抽取的输入：只有本轮真实发生的对话，不夹带猜测。
public struct MemoryExtractionInput: Sendable, Equatable {
    public var userText: String
    public var assistantText: String
    /// 已有事实摘要：用于让模型避免重复产出
    public var knownFacts: [String]

    public init(userText: String, assistantText: String, knownFacts: [String] = []) {
        self.userText = userText
        self.assistantText = assistantText
        self.knownFacts = knownFacts
    }
}

/// 抽取提示词。模型只负责"从对话里挑事实"，是否落库由 `MemoryExtractionPolicy.screen` 决定。
public enum MemoryExtractionPrompt {
    public static let version = "v1"

    public static let system = """
    你是记忆抽取器，只输出 JSON 数组，不要任何解释、前缀或代码块标记。
    从这一轮对话中抽取**值得长期记住**的事实，最多 8 条；没有就输出 []。

    每条字段：
    - subject: "user"（关于用户）/ "both"（关于我们）/ "self"（关于你自己）/ "unknown"（无法判断）
    - layer: "episodic"（一次具体经历）/ "semantic"（稳定事实）/ "procedural"（偏好与习惯做法）/ "reflective"（对关系的思考）
    - category: 小写英文，如 fact / preference / relationship / boundary / promise / identity / value / emotion_pattern / event
    - title: 不超过 20 字
    - content: 一句话完整陈述，主语明确
    - evidence: **必须逐字摘自用户原话**的片段，不得改写、不得拼接
    - importance: 0 到 1
    - confidence: 0 到 1

    硬规则：
    1. evidence 在用户原话中找不到就不要输出该条；
    2. 不推断用户没说过的喜好、身份、关系；
    3. 不把寒暄、工具调用、系统提示当作记忆；
    4. 同一条内容只出现一次。
    """

    public static func userMessage(for input: MemoryExtractionInput) -> String {
        var parts: [String] = []
        if !input.knownFacts.isEmpty {
            parts.append("已知事实（不要重复）：\n" + input.knownFacts.prefix(20).map { "- \($0)" }.joined(separator: "\n"))
        }
        parts.append("用户说：\n\(input.userText)")
        parts.append("助手回复：\n\(input.assistantText)")
        parts.append("只输出 JSON 数组。")
        return parts.joined(separator: "\n\n")
    }
}

/// 模型输出的单条原始结构。字段缺失或类型不符时整条丢弃，不做猜测性补齐。
private struct RawExtractedMemory: Decodable {
    var subject: String?
    var layer: String?
    var category: String?
    var title: String?
    var content: String?
    var evidence: String?
    var importance: Double?
    var confidence: Double?
}

/// 解析与筛查。任何异常都退化为"少记"，绝不写入半成品。
public enum MemoryExtractionParser {
    /// - Parameters:
    ///   - raw: 模型返回的原始文本（可能带 ```json 围栏或前后废话）
    ///   - sourceText: 本轮用户原话 + 助手回复，用于证据定位
    public static func parse(
        _ raw: String,
        sourceText: String,
        policy: MemoryExtractionPolicy = .default
    ) -> MemoryScreenResult {
        guard let json = jsonArraySubstring(in: raw),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([RawExtractedMemory].self, from: data) else {
            return MemoryScreenResult()
        }

        var candidates: [MemoryCandidate] = []
        for item in decoded {
            guard let content = item.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else { continue }
            let evidence = item.evidence?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !evidence.isEmpty else { continue }

            let subject = MemorySubject(rawValue: item.subject?.lowercased() ?? "unknown") ?? .unknown
            let resolved = MemoryGovernance.resolveScope(subject: subject)
            let layer = MemoryLayer(rawValue: item.layer?.lowercased() ?? "semantic") ?? .semantic
            // L1/L6/L7 不是抽取目标，落到语义层
            let persistedLayer = layer.persistsInMemories ? layer : .semantic
            let category = MemoryGovernance.normalizeCategory(item.category ?? "fact")

            candidates.append(
                MemoryCandidate(
                    scope: resolved.scope,
                    layer: persistedLayer,
                    category: category.isEmpty ? "fact" : category,
                    title: item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? String(content.prefix(20)),
                    content: content,
                    evidenceQuote: evidence,
                    importance: clamp(item.importance ?? 0.5),
                    confidence: clamp(item.confidence ?? 0.6),
                    scopeNeedsConfirmation: resolved.needsConfirmation
                )
            )
        }

        var screened = policy.screen(candidates, sourceText: sourceText)
        // 补全去重键，供落库时比对既有记忆
        screened.accepted = screened.accepted.map { candidate in
            var copy = candidate
            copy.dedupeKey = policy.normalizedDedupeKey(for: copy)
            return copy
        }
        return screened
    }

    /// 从可能包含围栏/前后说明的文本里截取第一个 JSON 数组。
    static func jsonArraySubstring(in raw: String) -> String? {
        guard let start = raw.firstIndex(of: "["),
              let end = raw.lastIndex(of: "]"),
              start < end else { return nil }
        return String(raw[start...end])
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }
}

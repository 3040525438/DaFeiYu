import Foundation

// MARK: - 跨域统一检索（D25）

/// 统一检索覆盖的域。
///
/// 四个域各自有独立的全文索引（`message_fts` / `memory_fts` / `diary_fts` / `attachment_text_fts`），
/// 本层只负责把命中汇总成同一种结构，**不合并排序**：不同 FTS 表的 bm25 分值不可横向比较。
public enum SearchDomain: String, Codable, Sendable, CaseIterable {
    case message
    case memory
    case diary
    case attachment

    public var displayName: String {
        switch self {
        case .message: return "聊天"
        case .memory: return "记忆"
        case .diary: return "日记"
        case .attachment: return "附件"
        }
    }
}

/// 一条统一检索命中。
///
/// 定位信息按域填充：
/// - 消息：`conversationID` + `messageID`（= targetID）；
/// - 记忆：`targetID` 即 memory_id；
/// - 日记：`targetID` 即 diary_id，`diaryDate` 为 `entry_date`；
/// - 附件：`targetID` 即 attachment_id，若已关联消息则同时给出 `conversationID` 与 `messageID`。
public struct UnifiedSearchHit: Codable, Sendable, Equatable, Identifiable {
    public var domain: SearchDomain
    public var targetID: String
    public var title: String
    /// 已按查询词定位的摘要（非整段原文）
    public var snippet: String
    /// bm25 原值，**越小越相关**；跨域不可直接比较
    public var score: Double
    public var conversationID: String?
    public var messageID: String?
    public var diaryDate: String?
    public var createdAt: Int64?

    /// 跨域唯一键（同一目标在不同域视为不同结果）
    public var id: String { "\(domain.rawValue):\(targetID)" }

    public init(
        domain: SearchDomain,
        targetID: String,
        title: String,
        snippet: String,
        score: Double,
        conversationID: String? = nil,
        messageID: String? = nil,
        diaryDate: String? = nil,
        createdAt: Int64? = nil
    ) {
        self.domain = domain
        self.targetID = targetID
        self.title = title
        self.snippet = snippet
        self.score = score
        self.conversationID = conversationID
        self.messageID = messageID
        self.diaryDate = diaryDate
        self.createdAt = createdAt
    }
}

/// 统一检索仓储。
///
/// 实现约束：
/// - 只返回未删除内容（消息还要求未撤回；附件还要求未软删）；
/// - **归档会话里的消息仍然可检索**（D51：归档不等于不可见）；
/// - 每个域最多返回 `limitPerDomain` 条，按该域相关度升序；
/// - 结果按 `SearchDomain.allCases` 的固定顺序分段返回，便于 UI 分组展示。
public protocol UnifiedSearchRepository: Sendable {
    func search(
        query: String,
        domains: Set<SearchDomain>,
        limitPerDomain: Int
    ) async throws -> [UnifiedSearchHit]
}

public extension UnifiedSearchRepository {
    /// 全领域检索的便捷入口。
    func search(query: String, limitPerDomain: Int = 20) async throws -> [UnifiedSearchHit] {
        try await search(
            query: query,
            domains: Set(SearchDomain.allCases),
            limitPerDomain: limitPerDomain
        )
    }
}

// MARK: - 摘要

/// 检索摘要（纯函数）。
///
/// `snippet()` 只能直接作用于 FTS 的 bigram 列，中文会得到碎片；因此摘要统一由本函数
/// 从原文字段截取：先定位查询词（找不到时退化为开头），再向两侧扩展。
public enum SearchSnippet {
    public static let defaultMaxLength = 80

    /// - Parameters:
    ///   - text: 原始正文（可能是多行）
    ///   - query: 用户查询（不做 FTS 语法解析）
    ///   - maxLength: 摘要最大字符数（不含省略号），下限 8
    public static func make(text: String, query: String, maxLength: Int = defaultMaxLength) -> String {
        let limit = max(8, maxLength)
        let cleaned = normalize(text)
        guard !cleaned.isEmpty else { return "" }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return head(cleaned, limit: limit) }

        for candidate in candidates(for: trimmedQuery) {
            guard let range = cleaned.range(
                of: candidate,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) else { continue }
            return window(cleaned, around: range, maxLength: limit)
        }
        return head(cleaned, limit: limit)
    }

    // MARK: 内部

    /// 换行与连续空白折叠为单个空格，避免摘要里出现大段空白
    static func normalize(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        var result = ""
        var lastWasSpace = false
        for character in collapsed {
            if character == " " {
                if !lastWasSpace { result.append(character) }
                lastWasSpace = true
            } else {
                result.append(character)
                lastWasSpace = false
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// 命中候选：完整查询 → 相邻二字 bigram → 英文整词
    static func candidates(for query: String) -> [String] {
        var results: [String] = [query]
        let characters = Array(query)
        if characters.count > 2 {
            for index in 0..<(characters.count - 1) {
                let pair = String(characters[index...index + 1])
                if !results.contains(pair) { results.append(pair) }
            }
        }
        for word in query.split(whereSeparator: { $0.isWhitespace }) where word.count >= 3 {
            let text = String(word)
            if !results.contains(text) { results.append(text) }
        }
        return results
    }

    static func head(_ text: String, limit: Int) -> String {
        let characters = Array(text)
        guard characters.count > limit else { return text }
        return String(characters.prefix(limit)) + "…"
    }

    /// 以命中处为中心取窗口：命中前保留约 1/3 宽度，尾部补满
    static func window(_ text: String, around range: Range<String.Index>, maxLength: Int) -> String {
        let characters = Array(text)
        let total = characters.count
        let hitStart = text.distance(from: text.startIndex, to: range.lowerBound)
        let hitLength = text.distance(from: range.lowerBound, to: range.upperBound)
        let lead = max(0, (maxLength - hitLength) / 3)

        var start = max(0, hitStart - lead)
        var end = min(total, start + maxLength)
        if end - start < maxLength {
            start = max(0, end - maxLength)
        }

        var snippet = String(characters[start..<end]).trimmingCharacters(in: .whitespaces)
        if start > 0 { snippet = "…" + snippet }
        if end < total { snippet += "…" }
        return snippet
    }
}

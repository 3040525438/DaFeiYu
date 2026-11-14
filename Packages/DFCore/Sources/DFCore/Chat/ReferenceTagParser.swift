import Foundation

/// 流式引用尾注解析器。
///
/// 协议形态（可选）：回复末尾单独一行 `<<refs:["id1","id2"]>>`。
/// 设计要点（r2.2.1）：
/// - 只在**回复末尾**识别尾注，正文中间的 `<<refs:` 视为普通文本；
/// - 疑似前缀最多扣留 12 字节，正文实时输出不受阻塞；
/// - 任何解析异常都退化为"整段当正文"，**绝不丢弃已生成的回复**；
/// - 剥离后正文与原文逐字符一致（除尾注片段外）。
public struct StreamingReferenceParser: Sendable {
    public static let tagOpen = "<<refs:"
    public static let maxRefs = 3
    public static let maxTagBytes = 512
    public static let maxProbeBytes = 12

    public struct Output: Sendable, Equatable {
        public var visibleText: String
        public var citations: [String]
        public var parseFailed: Bool
        public var failure: String?

        public init(visibleText: String, citations: [String], parseFailed: Bool, failure: String?) {
            self.visibleText = visibleText
            self.citations = citations
            self.parseFailed = parseFailed
            self.failure = failure
        }
    }

    private var raw = ""
    /// 已通过 `feed` 输出的字符数（`raw` 前缀长度）
    private var emitted = 0

    public init() {}

    /// 送入一段流式增量，返回本轮可安全显示的正文（可能为空串）。
    public mutating func feed(_ delta: String) -> String {
        guard !delta.isEmpty else { return "" }
        raw += delta
        let holdback = holdbackOffset()
        guard holdback > emitted else { return "" }

        let start = raw.index(raw.startIndex, offsetBy: emitted)
        let end = raw.index(raw.startIndex, offsetBy: holdback)
        emitted = holdback
        return String(raw[start..<end])
    }

    /// 结束流，返回最终正文与引用。
    public mutating func finish() -> Output {
        let holdback = holdbackOffset()
        guard holdback < raw.count else {
            return Output(visibleText: raw, citations: [], parseFailed: false, failure: nil)
        }

        // 没有尾注标记：扣留的只是正文里的 "<" 前缀，属于正常文本
        guard Self.occurrences(of: Self.tagOpen, in: raw) > 0 else {
            return Output(visibleText: raw, citations: [], parseFailed: false, failure: nil)
        }

        let tagText = String(raw.dropFirst(holdback))

        // 尾注出现多次：保守起见全部当正文
        if Self.occurrences(of: Self.tagOpen, in: raw) > 1 {
            return Output(visibleText: raw, citations: [], parseFailed: false, failure: "multiple_tags")
        }

        if tagText.utf8.count > Self.maxTagBytes {
            return Output(visibleText: raw, citations: [], parseFailed: true, failure: "tag_too_large")
        }

        do {
            let citations = try Self.parseCitations(tagText)
            let visible = String(raw.prefix(holdback))
            return Output(
                visibleText: visible,
                citations: Array(citations.prefix(Self.maxRefs)),
                parseFailed: false,
                failure: nil
            )
        } catch {
            // 解析失败时保留模型原始输出，绝不让正文丢失
            return Output(visibleText: raw, citations: [], parseFailed: true, failure: "invalid_tag")
        }
    }

    // MARK: - 扣留区间计算

    /// 返回"从此偏移开始不能输出"的位置（字符数）。
    private func holdbackOffset() -> Int {
        // 1. 末尾存在结构完整的尾注
        if let range = raw.range(of: Self.tagOpen, options: .backwards) {
            let after = raw[range.upperBound...]
            if Self.looksLikeCompleteTag(after) {
                return raw.distance(from: raw.startIndex, to: range.lowerBound)
            }
        }
        // 2. 末尾可能是尚未写完的尾注前缀
        let probe = min(raw.count, Self.maxProbeBytes)
        if probe > 0 {
            let tail = String(raw.suffix(probe))
            if let index = Self.partialTagStart(in: tail) {
                return raw.count - (tail.count - index)
            }
        }
        return raw.count
    }

    /// `after` 是否为 `[ ... ] >>` 形式（只判结构，JSON 合法性留给 `parseCitations`）
    private static func looksLikeCompleteTag(_ after: Substring) -> Bool {
        let text = after.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("["), text.hasSuffix(">>") else { return false }
        let json = String(text.dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        return json.hasPrefix("[") && json.hasSuffix("]")
    }

    /// 在尾部片段中找可能是 `<<refs:` 前缀的起始位置
    private static func partialTagStart(in tail: String) -> Int? {
        guard let lt = tail.lastIndex(of: "<") else { return nil }
        let candidate = String(tail[lt...])
        guard candidate.utf8.count <= maxProbeBytes else { return nil }
        if tagOpen.hasPrefix(candidate) || candidate.hasPrefix(tagOpen) {
            return tail.distance(from: tail.startIndex, to: lt)
        }
        return nil
    }

    // MARK: - JSON 解析

    private static func parseCitations(_ tagText: String) throws -> [String] {
        let text = tagText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(tagOpen), text.hasSuffix(">>") else {
            throw ParseError.malformed
        }
        let jsonPart = String(text.dropFirst(tagOpen.count).dropLast(2))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard jsonPart.hasPrefix("["), jsonPart.hasSuffix("]") else {
            throw ParseError.malformed
        }
        guard let data = jsonPart.data(using: .utf8) else {
            throw ParseError.malformed
        }
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let array = object as? [Any] else {
            throw ParseError.malformed
        }

        var seen = Set<String>()
        var result: [String] = []
        for element in array {
            guard let raw = element as? String else { throw ParseError.malformed }
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { throw ParseError.malformed }
            if seen.insert(id).inserted {
                result.append(id)
            }
        }
        return result
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var start = haystack.startIndex
        while let range = haystack.range(of: needle, range: start..<haystack.endIndex) {
            count += 1
            start = range.upperBound
        }
        return count
    }

    enum ParseError: Error {
        case malformed
    }
}

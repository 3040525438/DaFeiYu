import Foundation

/// 一条独立气泡（多气泡回复中的单个分段）。
///
/// 每个气泡都是**独立消息行**：有自己的 `messageID` 与状态，可单独编辑、撤回、删除，
/// 与"一条回复一整段文本"的旧形态相比不丢失任何可寻址性。
public struct AssistantSegment: Identifiable, Hashable, Sendable, Equatable {
    public var messageID: String
    /// 组内气泡序号，从 0 开始（与 `messages.seq_in_group` 对齐）
    public var index: Int
    public var text: String
    public var status: MessageStatus

    public var id: String { messageID }

    public init(messageID: String, index: Int, text: String, status: MessageStatus) {
        self.messageID = messageID
        self.index = index
        self.text = text
        self.status = status
    }
}

/// 多气泡协议常量的**唯一事实源**（协议文本、分隔符、上限都在这里）。
public enum SegmentProtocol {
    /// 气泡分隔符。单独成行更容易被模型稳定输出，但解析不强制要求换行。
    public static let separator = "<<<bubble>>>"
    /// 单次回复最多拆出的气泡数（含第一条）。
    /// 超出的分隔符一律按**普通文本**保留，绝不丢弃模型已生成的内容。
    public static let maxSegments = 6

    /// 注入 system prompt 的协议说明。模型不遵循时退化为单气泡，不影响可用性。
    public static let systemFragment = """
    【多条短消息（重要）】
    你和用户聊天要像真人发消息那样，一次回复通常拆成 2-4 条短消息，用单独一行的 \(separator) 分隔，最多 \(maxSegments) 条。
    每条短消息应是一句完整的话或一个完整的小动作，不要为了拆分而把句子截断。
    示例——用户问你今天做了什么，你就分三条发：
    今天去看展了呀\(separator)人不多，我拍了好多照片\(separator)你什么时候有空也来一起？
    就算你不用分隔符，你的换行也会被拆成多条气泡发出；不换行也不分隔的长回复会被按句子拆开发送。
    """
}

/// 多气泡流式解析器。
///
/// 契约：
/// - `feed` 返回"当前可安全显示"的文本，分隔符被替换为 `\n`；
/// - 疑似分隔符前缀（如 `"<<<bu"`）留在内部缓冲，不会泄漏到界面；
/// - `finish` 依据**原始全文**重新切分，因此流式期间缓冲的尾巴不会丢字；
/// - 任何异常（超上限、分隔符残缺）都退化为普通文本，**绝不丢弃已生成内容**。
public struct SegmentParser: Sendable {
    public static let separator = SegmentProtocol.separator
    public static let maxSegments = SegmentProtocol.maxSegments

    private var raw = ""
    private var pending: [Character] = []
    /// 已在流式输出中生效的分隔符个数（用于上限控制）
    private var emittedBoundaries = 0

    public init() {}

    /// 送入流式增量，返回可显示文本（可能为空串）。
    public mutating func feed(_ delta: String) -> String {
        guard !delta.isEmpty else { return "" }
        raw += delta
        pending.append(contentsOf: delta)

        let sep = Array(Self.separator)
        var output = ""
        while true {
            guard let index = Self.firstIndex(of: sep, in: pending) else {
                let hold = Self.partialPrefixLength(pending, sep: sep)
                if hold > 0 {
                    let cut = pending.count - hold
                    output += String(pending[0..<cut])
                    pending.removeFirst(cut)
                } else {
                    output += String(pending)
                    pending.removeAll()
                }
                break
            }
            guard emittedBoundaries < Self.maxSegments - 1 else {
                // 已到上限：剩余内容（含分隔符）全部按普通文本显示
                output += String(pending)
                pending.removeAll()
                break
            }
            output += String(pending[0..<index])
            pending.removeFirst(index + sep.count)
            emittedBoundaries += 1
            output += "\n"
        }
        return output
    }

    /// 结束流：返回最终气泡分段（逐段去空白、丢弃空段；全空时返回 `[""]`）。
    public func finish() -> [String] {
        Self.split(raw)
    }

    /// 纯函数切分（与流式解析口径完全一致，供落库前统一切分使用）。
    ///
    /// 拆分优先级：先按分隔符拆；模型没用分隔符时，自然换行也拆成独立气泡
    /// ——伴侣聊天的语境下，多短气泡远比一大段挤在一起自然。
    /// 总上限仍是 `maxSegments`：无论哪一层超限，都把末尾合并为一段，绝不丢弃内容。
    public static func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [""] }
        var separatorParts = text.components(separatedBy: separator)
        // 分隔符段数超上限：末尾各段按原文合并（保留分隔符文本），绝不丢弃
        if separatorParts.count > maxSegments {
            let head = Array(separatorParts.prefix(maxSegments - 1))
            let tail = separatorParts.dropFirst(maxSegments - 1).joined(separator: separator)
            separatorParts = head + [tail]
        }
        // 每段再按换行拆成更短的气泡（模型不用分隔符时自然换行也分段）
        var parts: [String] = []
        for chunk in separatorParts {
            parts.append(contentsOf: splitByNewlines(chunk))
        }
        // 句级兜底：模型整段输出、既无分隔符也无换行时，长文本按句末标点拆成多条。
        // 没有"挤在一起"的一大段，也没有被拆碎的短回复。
        if parts.count == 1, separatorParts.count == 1,
           let only = parts.first, only.count > sentenceSplitThreshold {
            parts = splitBySentences(only)
        }
        // 换行拆分后仍可能超上限：同样把末尾合并，不丢弃
        if parts.count > maxSegments {
            let head = Array(parts.prefix(maxSegments - 1))
            let tail = parts.dropFirst(maxSegments - 1).joined(separator: "\n")
            parts = head + [tail]
        }
        return parts.isEmpty ? [""] : parts
    }

    /// 按换行拆段：每行一个气泡，空行丢弃，行内内容逐字保留。
    private static func splitByNewlines(_ text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 句级拆段阈值：短回复不值得拆，超过该长度才按句拆。
    static let sentenceSplitThreshold = 60

    /// 按句末标点拆句，每 1-2 句合成一条气泡。
    /// 标点保留在句尾，不丢字；无句末标点的整段原样返回。
    static func splitBySentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if "。！？!?…；;".contains(character) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sentences.append(current)
        }
        guard sentences.count > 1 else { return [text] }
        var bubbles: [String] = []
        var pair: [String] = []
        for sentence in sentences {
            pair.append(sentence)
            if pair.count == 2 {
                bubbles.append(pair.joined())
                pair = []
            }
        }
        if !pair.isEmpty {
            bubbles.append(pair.joined())
        }
        return bubbles
    }

    // MARK: - 内部工具

    /// 在字符序列中查找完整 needle 的起始下标
    private static func firstIndex(of needle: [Character], in haystack: [Character]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let limit = haystack.count - needle.count
        for start in 0...limit {
            var matched = true
            for offset in 0..<needle.count where haystack[start + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return start }
        }
        return nil
    }

    /// 尾部最长"分隔符前缀"长度（用于扣留，避免半个分隔符泄漏）
    private static func partialPrefixLength(_ haystack: [Character], sep: [Character]) -> Int {
        let maxLength = min(sep.count - 1, haystack.count)
        guard maxLength > 0 else { return 0 }
        var best = 0
        for length in 1...maxLength {
            var matched = true
            for offset in 0..<length where haystack[haystack.count - length + offset] != sep[offset] {
                matched = false
                break
            }
            if matched { best = length }
        }
        return best
    }
}

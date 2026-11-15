import Foundation

// MARK: - 主动创建会话（D47）

/// 候选新会话：由调用方（模型判断 + 上下文）构造。
public struct NewConversationCandidate: Sendable, Equatable {
    /// 模型给出的标题草稿，可为空
    public var titleDraft: String
    /// 话题锚点：逐字来自上下文的一条片段，用于兜底标题
    public var topicAnchor: String?
    /// 去重键：同一话题只允许主动开一次会话
    public var dedupeKey: String

    public init(titleDraft: String, topicAnchor: String? = nil, dedupeKey: String) {
        self.titleDraft = titleDraft
        self.topicAnchor = topicAnchor
        self.dedupeKey = dedupeKey
    }
}

/// 已有会话的精简视图（策略只依赖这些字段，避免把整张表读进内存）。
public struct ExistingConversationBrief: Sendable, Equatable {
    public var id: String
    public var title: String
    public var createdAt: Int64
    public var isArchived: Bool

    public init(id: String, title: String, createdAt: Int64, isArchived: Bool) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.isArchived = isArchived
    }
}

/// 新会话决策结果。三种情况都必须在执行记录里留痕。
public enum NewConversationDecision: Sendable, Equatable {
    /// 新建会话
    case create(title: String, reason: String)
    /// 已有同主题会话，直接复用（不新建、不打扰用户两次）
    case reuse(conversationID: String, title: String, reason: String)
    /// 不开新会话
    case skip(reason: String)

    /// 给用户 / 执行记录看的中文说明
    public var summary: String {
        switch self {
        case .create(let title, let reason): return "新建会话「\(title)」：\(reason)"
        case .reuse(_, let title, let reason): return "复用已有会话「\(title)」：\(reason)"
        case .skip(let reason): return "不新开会话：\(reason)"
        }
    }
}

/// 主动创建会话的策略（纯函数，不读时钟、不读库）。
///
/// 设计目标（D47）：
/// - 只在"确有新话题"时才开新会话，避免把一段连续对话拆成多个会话；
/// - 同主题已有会话时**复用**而不是重复创建；
/// - 有时间间隔与每日上限两道闸，防止无意义刷屏；
/// - 标题必须可读：空 / 纯标点 / 超长一律规范化或回退默认。
public enum NewConversationPolicy {
    /// 两次主动新开会话的最小间隔（分钟）：6 小时
    public static let minIntervalMinutes = 360
    /// 每日主动新开会话上限
    public static let dailyLimit = 2
    /// 标题最大长度（字符）
    public static let maxTitleLength = 20
    /// 标题最小长度（规范化后不足则视为没有话题）
    public static let minTitleLength = 2
    /// 兜底标题
    public static let defaultTitle = "和大肥鱼聊聊"

    /// 标题规范化：去换行与连续空白、去首尾标点、截断。
    ///
    /// 换行与制表符直接删除（中文标题里换行不承担空格语义），
    /// 其余连续空格折叠为一个。
    /// - Returns: 不足 `minTitleLength` 时返回空串（表示没有可用话题）
    public static func normalizeTitle(_ raw: String) -> String {
        let flattened = raw
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: " ")
        let collapsed = flattened
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let trimmed = collapseRepeatedPunctuation(collapsed)
            .trimmingCharacters(in: titleTrimSet)
        guard trimmed.count >= minTitleLength else { return "" }
        return String(trimmed.prefix(maxTitleLength))
    }

    /// 从候选推导标题：优先模型草稿，其次话题锚点，最后空串。
    public static func deriveTitle(from candidate: NewConversationCandidate) -> String {
        let draft = normalizeTitle(candidate.titleDraft)
        if !draft.isEmpty { return draft }
        if let anchor = candidate.topicAnchor {
            let fromAnchor = normalizeTitle(anchor)
            if !fromAnchor.isEmpty { return fromAnchor }
        }
        return ""
    }

    /// 标题是否指向同一主题。
    ///
    /// 依次判断：完全相等 → 一方包含另一方 → 存在长度 ≥ 2 的公共实词片段。
    /// 公共片段用于识别「聊聊体检」与「体检结果」这类同主题的不同说法；
    /// 停用词（"今天""我们"等）不计入，避免把任意两句话判成同一话题。
    public static func titlesOverlap(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalizeTitle(lhs)
        let b = normalizeTitle(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        guard min(a.count, b.count) >= minTitleLength else { return false }
        if a.contains(b) || b.contains(a) { return true }
        return sharesTopicFragment(a, b)
    }

    /// 是否存在长度 ≥ 2 的公共非停用词片段
    static func sharesTopicFragment(_ a: String, _ b: String) -> Bool {
        let short = Array(a.count <= b.count ? a : b)
        let long = a.count <= b.count ? b : a
        guard short.count >= minTitleLength else { return false }
        for length in stride(from: short.count, through: minTitleLength, by: -1) {
            guard short.count >= length else { continue }
            for start in 0...(short.count - length) {
                let piece = String(short[start..<(start + length)])
                guard !stopWords.contains(piece) else { continue }
                if long.contains(piece) { return true }
            }
        }
        return false
    }

    /// 核心决策。
    ///
    /// - Parameters:
    ///   - candidate: 候选新会话
    ///   - existing: 已有会话（含归档；归档会话不作为复用目标）
    ///   - lastCreatedAt: 上次**主动**新开会话的时间；nil 表示从未开过
    ///   - createdToday: 今天已主动新开的会话数
    ///   - nowMillis: 当前时间
    ///   - usedDedupeKeys: 已经用过的去重键
    public static func decide(
        candidate: NewConversationCandidate,
        existing: [ExistingConversationBrief],
        lastCreatedAt: Int64?,
        createdToday: Int,
        nowMillis: Int64,
        usedDedupeKeys: Set<String> = []
    ) -> NewConversationDecision {
        // 1. 同一话题只开一次
        let key = candidate.dedupeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty, usedDedupeKeys.contains(key) {
            return .skip(reason: "这个话题之前已经主动开过会话")
        }

        // 2. 必须有可读的标题，否则说明没有明确话题
        let title = deriveTitle(from: candidate)
        guard !title.isEmpty else {
            return .skip(reason: "没有足够明确的新话题")
        }

        // 3. 已存在同主题会话 → 复用，不重复创建
        let active = existing.filter { !$0.isArchived }
        if let match = active.first(where: { titlesOverlap($0.title, title) }) {
            return .reuse(
                conversationID: match.id,
                title: match.title,
                reason: "已有同主题会话，直接在那里继续"
            )
        }

        // 4. 每日上限
        if createdToday >= dailyLimit {
            return .skip(reason: "今天已主动开启 \(createdToday) 个会话，达到上限 \(dailyLimit) 个")
        }

        // 5. 最小间隔（时钟回拨视为不满足，避免异常时间戳绕过）
        if let lastCreatedAt {
            let elapsed = Double(nowMillis - lastCreatedAt) / 60_000
            if elapsed < Double(minIntervalMinutes) {
                let remaining = Int((Double(minIntervalMinutes) - elapsed).rounded(.up))
                return .skip(reason: "距上次主动开启会话不足 \(minIntervalMinutes) 分钟，还需 \(remaining) 分钟")
            }
        }

        return .create(title: title, reason: "出现了值得单独聊的新话题")
    }

    // MARK: - 内部

    /// 需要从标题首尾去掉的标点
    private static let titleTrimSet = CharacterSet(
        charactersIn: " \t\n\r。！？，、；：.!?,;:\"'“”‘’（）()【】[]…—-·~`"
    )
    /// 连续重复的句末标点折叠为一个，避免标题读起来像噪声
    private static let repeatedPunctuation: [Character] = ["。", "！", "？", "…", "!", "?", "."]

    /// 判同主题时忽略的常见虚词 / 时间词，避免"今天怎么样"与"今天累吗"被判成同一话题
    private static let stopWords: Set<String> = [
        "我的", "你的", "我们", "你们", "他们", "自己",
        "今天", "明天", "昨天", "现在", "最近", "刚才",
        "这个", "那个", "一个", "什么", "怎么", "为什么",
        "可以", "还是", "就是", "不是", "真的", "有点",
        "一下", "然后", "因为", "所以", "但是", "如果",
        "聊聊", "说说", "关于", "一些", "事情"
    ]

    private static func collapseRepeatedPunctuation(_ text: String) -> String {
        var result = ""
        var previous: Character?
        for character in text {
            if let previous,
               previous == character,
               repeatedPunctuation.contains(character) {
                continue
            }
            result.append(character)
            previous = character
        }
        return result
    }
}

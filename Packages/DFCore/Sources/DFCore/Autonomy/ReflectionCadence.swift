import Foundation

// MARK: - 自我反思的节奏与紧迫度（借鉴 Shikigami 的机制，独立实现）
//
// 借鉴边界（ADR-09）：
// - 只借鉴"严格 Schema 校验 + 紧迫度夹取 + 自适应反思间隔 + 重启续算 + 节奏信号"这套机制；
// - 不复制 AGPL-3.0 源码，不使用 Python / FastAPI / Electron 作为 iOS 运行依赖；
// - 全部为纯函数与值类型，不读时钟、不读数据库，便于在 CI 上覆盖异常输入与边界值。

/// 反思结论中"为什么想说话"的枚举。
///
/// 模型只能从这个闭集中取值，避免自由文本进入投递判断。
/// `none` 表示本次不想说话。
public enum ReflectionSpeakReason: String, Codable, Sendable, CaseIterable {
    /// 想起了某段具体记忆
    case memoryRecall = "memory_recall"
    /// 想分享最近的趋势 / 变化
    case trendShare = "trend_share"
    /// 情绪积压，需要表达
    case emotionalOverflow = "emotional_overflow"
    /// 用户很久没说话，想关心一下
    case silenceConcern = "silence_concern"
    /// 不想说话
    case none
}

/// 一次反思的规范化结果。
///
/// 所有字段都是"已经过校验与夹取"的安全值：
/// - `urgency` 恒在 0...1；
/// - `nextReflectionIn` 恒在 `ReflectionCadence.minIntervalSeconds...maxIntervalSeconds`；
/// - `speakReason` 恒为闭集成员。
public struct ReflectionState: Sendable, Equatable {
    /// 内心独白（不直接展示给用户）
    public var thought: String
    /// 可选的语气提示，用于下一次回复的风格微调
    public var styleHint: String?
    /// 说话紧迫度，0...1
    public var urgency: Double
    /// 本次想聊的话题标签（可选）
    public var topicPick: String?
    /// 话题的锚点：来自上下文的一条逐字片段（可选）
    public var topicAnchor: String?
    /// 下一次反思间隔（秒）
    public var nextReflectionIn: Int
    /// 说话的理由
    public var speakReason: ReflectionSpeakReason

    public init(
        thought: String,
        styleHint: String? = nil,
        urgency: Double,
        topicPick: String? = nil,
        topicAnchor: String? = nil,
        nextReflectionIn: Int = ReflectionCadence.defaultIntervalSeconds,
        speakReason: ReflectionSpeakReason = .none
    ) {
        self.thought = thought
        self.styleHint = styleHint
        self.urgency = ReflectionCadence.clampUrgency(urgency)
        self.topicPick = topicPick
        self.topicAnchor = topicAnchor
        self.nextReflectionIn = ReflectionCadence.clampInterval(nextReflectionIn)
        self.speakReason = speakReason
    }

    /// 解析失败或模型明确不想说话时的保守默认值：不投递、按默认间隔重排。
    public static let `default` = ReflectionState(
        thought: "",
        styleHint: nil,
        urgency: 0,
        topicPick: nil,
        topicAnchor: nil,
        nextReflectionIn: ReflectionCadence.defaultIntervalSeconds,
        speakReason: .none
    )

    /// 是否表达了"想说话"的意图（仅看理由，不看紧迫度）
    public var wantsToSpeak: Bool { speakReason != .none }
}

// MARK: - 解析失败原因

/// 解析失败原因。失败时一律回退默认值，**不抛错、不崩溃**。
public enum ReflectionParseFailure: String, Sendable, Equatable {
    case emptyOutput
    case notJSONObject
    case unknownKeys
    case missingKeys
    case invalidTypes
    case invalidSpeakReason
}

/// 解析结果：既有可用状态，也有"为什么降级"。
public struct ReflectionParseResult: Sendable, Equatable {
    public var state: ReflectionState
    /// nil 表示严格校验全部通过
    public var failure: ReflectionParseFailure?

    public init(state: ReflectionState, failure: ReflectionParseFailure?) {
        self.state = state
        self.failure = failure
    }

    public var isStrict: Bool { failure == nil }
}

// MARK: - 严格解析器

/// 反思输出的严格 JSON 解析器。
///
/// Schema（键集必须完全一致，多键 / 少键都判失败）：
/// ```json
/// {
///   "thought": "string",
///   "style_hint": "string|null",
///   "urgency": 0.0,
///   "topic_pick": "string|null",
///   "topic_anchor": "string|null",
///   "next_reflection_in": 900,
///   "speak_reason": "memory_recall|trend_share|emotional_overflow|silence_concern|none"
/// }
/// ```
public enum ReflectionOutputParser {
    /// 允许出现的全部键
    public static let allowedKeys: Set<String> = [
        "thought", "style_hint", "urgency", "topic_pick",
        "topic_anchor", "next_reflection_in", "speak_reason"
    ]

    /// 必须出现的键（其余可显式写 null，但键本身不能缺）
    public static let requiredKeys: Set<String> = [
        "thought", "urgency", "next_reflection_in", "speak_reason"
    ]

    /// 解析模型原始输出。任何异常都降级为默认状态并附上失败原因。
    public static func parse(_ raw: String) -> ReflectionParseResult {
        let text = stripCodeFence(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return ReflectionParseResult(state: .default, failure: .emptyOutput)
        }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return ReflectionParseResult(state: .default, failure: .notJSONObject)
        }

        let keys = Set(dict.keys)
        guard keys.subtracting(allowedKeys).isEmpty else {
            return ReflectionParseResult(state: .default, failure: .unknownKeys)
        }
        guard requiredKeys.isSubset(of: keys) else {
            return ReflectionParseResult(state: .default, failure: .missingKeys)
        }

        guard let thought = dict["thought"] as? String else {
            return ReflectionParseResult(state: .default, failure: .invalidTypes)
        }
        guard let urgencyNumber = dict["urgency"] as? NSNumber else {
            return ReflectionParseResult(state: .default, failure: .invalidTypes)
        }
        // JSON 里不会出现 NaN，但历史上出现过字符串形式的数字，这里一律判失败
        let urgency = urgencyNumber.doubleValue
        guard urgency.isFinite else {
            return ReflectionParseResult(state: .default, failure: .invalidTypes)
        }
        guard let reasonRaw = dict["speak_reason"] as? String,
              let reason = ReflectionSpeakReason(rawValue: reasonRaw) else {
            return ReflectionParseResult(state: .default, failure: .invalidSpeakReason)
        }

        var interval = ReflectionCadence.defaultIntervalSeconds
        if let rawInterval = dict["next_reflection_in"], !(rawInterval is NSNull) {
            guard let number = rawInterval as? NSNumber, number.doubleValue.isFinite else {
                return ReflectionParseResult(state: .default, failure: .invalidTypes)
            }
            interval = number.intValue
        }

        let state = ReflectionState(
            thought: thought.trimmingCharacters(in: .whitespacesAndNewlines),
            styleHint: optionalString(dict["style_hint"]),
            urgency: urgency,
            topicPick: optionalString(dict["topic_pick"]),
            topicAnchor: optionalString(dict["topic_anchor"]),
            nextReflectionIn: ReflectionCadence.clampInterval(interval),
            speakReason: reason
        )
        return ReflectionParseResult(state: state, failure: nil)
    }

    /// 可选字符串：`null` / 缺省 → nil；类型不对 → nil（不因此判整体失败）
    private static func optionalString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 去掉模型常见的 ```json 代码围栏，只做外壳剥离，不放宽 Schema。
    /// 内部可见：洞察解析器复用同一套围栏剥离逻辑，避免两处行为漂移。
    static func stripCodeFence(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var lines = trimmed.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return trimmed }
        lines.removeFirst()
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 节奏规则

/// 反思节奏的统一规则入口。
public enum ReflectionCadence {
    /// 默认反思间隔：15 分钟
    public static let defaultIntervalSeconds = 900
    /// 间隔下限：1 分钟（防止模型要求"立刻反复反思"打爆预算）
    public static let minIntervalSeconds = 60
    /// 间隔上限：60 分钟
    public static let maxIntervalSeconds = 3600

    /// 保守档阈值：只有很强烈的表达欲才打扰
    public static let conservativeThreshold = 0.6
    /// 平衡档阈值
    public static let balancedThreshold = 0.35
    /// 积极档阈值
    public static let eagerThreshold = 0.2

    /// 把紧迫度夹到 0...1；NaN / 无穷返回 0。
    public static func clampUrgency(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    /// 把反思间隔夹到合法域；非正数与 0 一律回退默认值。
    public static func clampInterval(_ seconds: Int) -> Int {
        guard seconds > 0 else { return defaultIntervalSeconds }
        return min(max(seconds, minIntervalSeconds), maxIntervalSeconds)
    }

    /// 是否值得开口：理由非 none 且紧迫度达到阈值。
    public static func shouldSpeak(
        urgency: Double,
        speakReason: ReflectionSpeakReason,
        threshold: Double = balancedThreshold
    ) -> Bool {
        guard speakReason != .none else { return false }
        return clampUrgency(urgency) >= clampUrgency(threshold)
    }

    /// 重启续算：根据"上次更新时间 + 上次给出的间隔"推算还需要等多久。
    ///
    /// - `lastUpdatedAt == nil`（从未反思过）→ 0，立即允许一次；
    /// - 已过期 → 0；
    /// - 未到期 → 剩余毫秒。
    public static func resumeDelayMillis(
        lastUpdatedAt: Int64?,
        intervalSeconds: Int,
        nowMillis: Int64
    ) -> Int64 {
        guard let lastUpdatedAt else { return 0 }
        let interval = Int64(clampInterval(intervalSeconds)) * 1000
        let due = lastUpdatedAt + interval
        return max(0, due - nowMillis)
    }
}

// MARK: - 节奏信号（cadence）

/// 用户互动节奏信号：由真实消息时间戳推导，不依赖任何后台计时器。
///
/// 用途：避免"用户刚刚连续发了一堆消息，AI 又主动插话"这类不合时宜的打扰。
public struct CadenceSignals: Sendable, Equatable {
    /// 窗口内的样本条数
    public var recentCount: Int
    /// 窗口内相邻样本的平均间隔（分钟）；样本不足 2 条时为 nil
    public var averageGapMinutes: Double?
    /// 最后一条样本到现在的间隔（分钟）
    public var lastGapMinutes: Double?
    /// 用户正在高频互动（短时间内连续多条）
    public var isQuick: Bool
    /// 用户已经安静较久
    public var isSlow: Bool

    public init(
        recentCount: Int,
        averageGapMinutes: Double?,
        lastGapMinutes: Double?,
        isQuick: Bool,
        isSlow: Bool
    ) {
        self.recentCount = recentCount
        self.averageGapMinutes = averageGapMinutes
        self.lastGapMinutes = lastGapMinutes
        self.isQuick = isQuick
        self.isSlow = isSlow
    }

    /// 默认窗口：60 分钟
    public static let defaultWindowMinutes: Double = 60
    /// 只保留最近 20 条样本，避免长会话反复计算
    public static let maxSamples = 20
    /// 高频判定：窗口内条数下限
    public static let quickCountThreshold = 6
    /// 高频判定：平均间隔上限（分钟）
    public static let quickGapMinutes: Double = 5
    /// 安静判定：最后一条消息距今（分钟）
    public static let slowGapMinutes: Double = 180

    /// 空信号：窗口内没有任何互动
    public static let idle = CadenceSignals(
        recentCount: 0,
        averageGapMinutes: nil,
        lastGapMinutes: nil,
        isQuick: false,
        isSlow: false
    )

    /// 由消息时间戳（毫秒）计算节奏信号。
    ///
    /// - 输入会自动排序、截断到最近 `maxSamples` 条；
    /// - 晚于 `nowMillis` 的时间戳（时钟漂移）会被忽略；
    /// - 全程纯函数，重复调用结果一致。
    public static func compute(
        timestamps: [Int64],
        nowMillis: Int64,
        windowMinutes: Double = defaultWindowMinutes
    ) -> CadenceSignals {
        let windowMillis = Int64(max(0, windowMinutes) * 60_000)
        let sorted = timestamps
            .filter { $0 <= nowMillis }
            .sorted()
            .suffix(maxSamples)
        guard !sorted.isEmpty else { return .idle }

        let windowStart = nowMillis - windowMillis
        let inWindow = sorted.filter { $0 >= windowStart }
        // "安静多久"以全部样本中最后一条为准：窗口外的历史同样说明用户已经安静
        let lastGap = Double(nowMillis - (sorted.last ?? nowMillis)) / 60_000

        var gaps: [Double] = []
        if inWindow.count >= 2 {
            for index in 1..<inWindow.count {
                gaps.append(Double(inWindow[index] - inWindow[index - 1]) / 60_000)
            }
        }
        let averageGap = gaps.isEmpty ? nil : gaps.reduce(0, +) / Double(gaps.count)

        let isQuick = inWindow.count >= quickCountThreshold
            && (averageGap ?? .infinity) <= quickGapMinutes
        let isSlow = lastGap >= slowGapMinutes

        return CadenceSignals(
            recentCount: inWindow.count,
            averageGapMinutes: averageGap,
            lastGapMinutes: lastGap,
            isQuick: isQuick,
            isSlow: isSlow
        )
    }
}

// MARK: - 与自主闸门联动

/// 反思节奏对主动行为的附加约束。
///
/// 只做"收紧"，绝不放宽既有五重闸门；`AutonomyGate` 在原有结论为放行时才使用它。
public enum ReflectionRhythm {
    /// 额外的拦截原因；nil 表示节奏上没有异议。
    ///
    /// - 用户正在高频互动（`isQuick`）→ 不要插话，避免打断；
    /// - 紧迫度低于阈值 → 不值得打扰。
    public static func blockReason(
        signals: CadenceSignals?,
        urgency: Double,
        speakReason: ReflectionSpeakReason,
        threshold: Double = ReflectionCadence.balancedThreshold
    ) -> String? {
        if let signals, signals.isQuick {
            return "用户正在连续互动，暂不主动打扰"
        }
        if !ReflectionCadence.shouldSpeak(
            urgency: urgency,
            speakReason: speakReason,
            threshold: threshold
        ) {
            return "反思紧迫度不足，暂不打扰"
        }
        return nil
    }
}

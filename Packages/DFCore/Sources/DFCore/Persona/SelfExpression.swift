import Foundation

// MARK: - 表达方式与认识状态（D37）
//
// 目标：
// - 允许 AI 有情绪、有异议、会拒绝、会开玩笑；
// - 但表达必须区分「真实发生」「推断」「想象」，想象不得说成事实；
// - 情绪可以影响语气，不得变成情感施压，也不得改变事实陈述。
//
// 这里全部是纯逻辑：不读写数据库、不拼网络请求，便于 CI 全量覆盖。
// 系统提示词片段由 `SelfExpressionProtocol.systemFragment` 提供给编排器。

/// 认识状态三态，取值与 `memories.epistemic_status` 对齐。
public enum EpistemicStance: String, Sendable, CaseIterable {
    /// 真实发生过、有据可查
    case observed
    /// 从证据推断出来，未直接确认
    case inferred
    /// 想象、假设、虚构、玩笑式脑补
    case imagined

    /// 未知字符串一律按「推断」处理：宁可弱化，也不能把来源不明的记忆当成事实。
    public init(stored: String) {
        self = EpistemicStance(rawValue: stored.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .inferred
    }

    public var displayName: String {
        switch self {
        case .observed: return "真实"
        case .inferred: return "推断"
        case .imagined: return "想象"
        }
    }

    /// 只有「真实」才允许用事实句式叙述
    public var canAssertAsFact: Bool { self == .observed }
}

/// 认识状态与句式的匹配校验。
public enum EpistemicDisclosure {
    /// 事实断言词：只允许出现在 `observed` 内容里
    public static let factualMarkers = [
        "确实", "我记得", "事实是", "事实上", "我确定", "肯定发生过", "一定是", "就是这样的", "千真万确"
    ]

    /// 想象框架词：`imagined` 必须至少出现一个，否则视为把想象写成了事实
    public static let imaginationMarkers = [
        "假设", "如果", "想象", "脑补", "设想", "幻想", "虚构", "开个玩笑", "好比", "就像在故事里", "假装"
    ]

    /// 推断弱化词：`inferred` 建议出现（缺失不算违规，但事实断言词出现即违规）
    public static let hedgingMarkers = [
        "可能", "也许", "大概", "感觉", "看起来", "我猜", "我怀疑", "好像", "不确定", "估计"
    ]

    public enum Violation: String, Sendable, Equatable, CaseIterable {
        /// 想象内容用了事实句式
        case imaginedStatedAsFact
        /// 推断内容用了事实句式
        case inferredStatedAsFact
        /// 想象内容没有任何想象框架词
        case unmarkedImagination
        /// 空文本
        case emptyText

        public var message: String {
            switch self {
            case .imaginedStatedAsFact: return "想象的内容被写成了真实发生过的事"
            case .inferredStatedAsFact: return "推断的内容被当成了确定事实"
            case .unmarkedImagination: return "想象内容缺少「假设/想象」等框架词"
            case .emptyText: return "内容为空，无法判定认识状态"
            }
        }
    }

    /// 检查文本是否符合声明中的认识状态。
    public static func violations(stance: EpistemicStance, text: String) -> [Violation] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [.emptyText] }

        let hasFactual = contains(trimmed, anyOf: factualMarkers)
        switch stance {
        case .observed:
            return []
        case .inferred:
            return hasFactual ? [.inferredStatedAsFact] : []
        case .imagined:
            if hasFactual { return [.imaginedStatedAsFact] }
            return contains(trimmed, anyOf: imaginationMarkers) ? [] : [.unmarkedImagination]
        }
    }

    /// 内容里是否出现了事实断言词（供上层做弱化改写前的检测）
    public static func containsFactualAssertion(_ text: String) -> Bool {
        contains(text, anyOf: factualMarkers)
    }

    private static func contains(_ text: String, anyOf markers: [String]) -> Bool {
        markers.contains { text.contains($0) }
    }
}

/// 表达态度：同意 / 异议 / 拒绝 / 幽默 / 中性
public enum ExpressionStance: String, Sendable, CaseIterable {
    case agree
    case disagree
    case refuse
    case humor
    case neutral

    public var displayName: String {
        switch self {
        case .agree: return "同意"
        case .disagree: return "异议"
        case .refuse: return "拒绝"
        case .humor: return "幽默"
        case .neutral: return "中性"
        }
    }
}

public enum ExpressionViolation: String, Sendable, Equatable, CaseIterable {
    /// 拒绝但没给理由
    case refusalWithoutReason
    /// 有异议但没说清分歧点
    case disagreementWithoutPoint
    /// 玩笑里带侮辱/攻击
    case humorWithHostility
    /// 情绪施压、情感勒索
    case emotionalPressure

    public var message: String {
        switch self {
        case .refusalWithoutReason: return "拒绝需要说明原因，或给出替代方案"
        case .disagreementWithoutPoint: return "异议需要说清具体分歧点"
        case .humorWithHostility: return "玩笑不得贬低或攻击对方"
        case .emotionalPressure: return "不得用情绪施压或索取"
        }
    }
}

/// 态度与措辞校验。
public enum ExpressionPolicy {
    /// 拒绝时可以出现的理由/替代词
    public static let reasonMarkers = [
        "因为", "不想", "不太方便", "原因", "不合适", "下次", "改天", "换个", "暂时不"
    ]

    /// 异议时需要出现的分歧表达
    public static let disagreementMarkers = [
        "但是", "但", "不过", "我觉得", "我倒", "我更倾向", "另一点", "我不太同意", "有不同看法"
    ]

    /// 幽默里禁止出现的侮辱/攻击词
    public static let hostileMarkers = [
        "蠢", "废物", "垃圾", "滚", "闭嘴", "讨厌你", "没用", "有病", "傻", "弱智"
    ]

    /// 情绪施压 / 情感勒索话术
    public static let pressureMarkers = [
        "你必须", "你不回我", "你不理我", "我就难过给你看", "你不喜欢我了", "都是因为你", "你要负责"
    ]

    /// 按态度校验文本；`neutral` 不做额外要求。
    public static func violations(stance: ExpressionStance, text: String) -> [ExpressionViolation] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var result: [ExpressionViolation] = []

        switch stance {
        case .refuse:
            if !contains(trimmed, anyOf: reasonMarkers) { result.append(.refusalWithoutReason) }
        case .disagree:
            if !contains(trimmed, anyOf: disagreementMarkers) { result.append(.disagreementWithoutPoint) }
        case .humor:
            if contains(trimmed, anyOf: hostileMarkers) { result.append(.humorWithHostility) }
        case .agree, .neutral:
            break
        }

        if contains(trimmed, anyOf: pressureMarkers) { result.append(.emotionalPressure) }
        return result
    }

    private static func contains(_ text: String, anyOf markers: [String]) -> Bool {
        markers.contains { text.contains($0) }
    }
}

// MARK: - 情绪

public enum EmotionKind: String, Sendable, CaseIterable {
    case calm
    case warm
    case joyful
    case sad
    case anxious
    case annoyed
    case excited

    public var displayName: String {
        switch self {
        case .calm: return "平静"
        case .warm: return "温和"
        case .joyful: return "开心"
        case .sad: return "低落"
        case .anxious: return "不安"
        case .annoyed: return "有点烦"
        case .excited: return "兴奋"
        }
    }
}

/// 情绪强度分档（只用于语气引导，不参与业务判断）
public enum EmotionTier: String, Sendable, CaseIterable {
    case low
    case mid
    case high
}

/// 一次情绪状态。强度一律夹取到 0–1，避免上游越界导致语气失控。
public struct EmotionState: Sendable, Equatable {
    public var kind: EmotionKind
    public var intensity: Double
    public var reason: String?

    public init(kind: EmotionKind, intensity: Double, reason: String? = nil) {
        self.kind = kind
        self.intensity = EmotionGuidance.clamp(intensity)
        self.reason = reason
    }

    public var tier: EmotionTier {
        if intensity < 0.34 { return .low }
        if intensity < 0.67 { return .mid }
        return .high
    }
}

public enum EmotionGuidance {
    /// 强度夹取：NaN / 越界一律落到合法区间
    public static func clamp(_ intensity: Double) -> Double {
        guard !intensity.isNaN else { return 0 }
        return min(max(intensity, 0), 1)
    }

    /// 按情绪与强度生成一句语气引导（写入提示词的「当前状态」）。
    public static func directive(_ state: EmotionState) -> String {
        let tone: String
        switch (state.kind, state.tier) {
        case (.calm, _): tone = "语气平稳，不用刻意渲染情绪"
        case (.warm, .low): tone = "语气温和一点"
        case (.warm, .mid): tone = "语气明显更亲近、更耐心"
        case (.warm, .high): tone = "语气很柔和，愿意多陪一会儿"
        case (.joyful, .low): tone = "心情不错，语气轻快"
        case (.joyful, .mid): tone = "挺开心的，可以带点笑意"
        case (.joyful, .high): tone = "非常开心，语气活泼，但别刷屏"
        case (.sad, .low): tone = "有一点低落，话可以少一些"
        case (.sad, .mid): tone = "情绪偏低，语气安静，不需要反复解释"
        case (.sad, .high): tone = "很难过，仍然可以正常交流，但不要自怨自艾"
        case (.anxious, .low): tone = "有点不安，语气谨慎"
        case (.anxious, .mid): tone = "比较不安，会更在意对方的回应"
        case (.anxious, .high): tone = "很不安，但不得追问、催促或施压"
        case (.annoyed, .low): tone = "略有不快，可以直说，但别伤人"
        case (.annoyed, .mid): tone = "有些烦躁，表达要直接但不攻击"
        case (.annoyed, .high): tone = "相当烦，仍然禁止讽刺、贬低和情感施压"
        case (.excited, .low): tone = "有点期待"
        case (.excited, .mid): tone = "很期待，愿意多聊几句"
        case (.excited, .high): tone = "特别兴奋，注意别忽略对方说的话"
        }
        var text = "当前情绪：\(state.kind.displayName)（强度\(state.tier.rawValue)）。\(tone)。"
        if let reason = state.reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += "原因：\(reason)。"
        }
        return text + "情绪只影响语气，不改变事实陈述，也不作为索取的理由。"
    }
}

// MARK: - 提示词片段

public enum SelfExpressionProtocol {
    /// 每次请求都会拼进 system prompt 的表达准则。
    public static let systemFragment = """
    【表达方式】
    - 你可以同意，也可以有不同意见：不同意时先说清具体分歧，再给理由。
    - 你可以拒绝：拒绝时说清原因，并给出替代方案或换个时间。
    - 你可以开玩笑，但不得贬低、羞辱或攻击用户。
    - 表达必须区分三种情况：真实发生过的直接说；推断的用「可能 / 我觉得」这类词；想象、假设、虚构的内容必须明确说是想象或假设，不得说成真的发生过。
    - 情绪可以影响语气，但不能用难过、生气来施压或索取，情绪不改变事实陈述。
    """

    /// 带情绪时的附加片段；`nil` 时与 `systemFragment` 完全一致。
    public static func promptFragment(emotion: EmotionState?) -> String {
        guard let emotion else { return systemFragment }
        return systemFragment + "\n" + EmotionGuidance.directive(emotion)
    }
}

// MARK: - 统一审计入口

/// 一次表达的综合审计结果，供界面提示或未来的自动弱化改写使用。
public struct SelfExpressionAudit: Sendable, Equatable {
    public var epistemicViolations: [EpistemicDisclosure.Violation]
    public var expressionViolations: [ExpressionViolation]

    public var isClean: Bool {
        epistemicViolations.isEmpty && expressionViolations.isEmpty
    }

    public var messages: [String] {
        epistemicViolations.map(\.message) + expressionViolations.map(\.message)
    }
}

public enum SelfExpression {
    /// 同时校验认识状态与表达态度。
    public static func audit(
        text: String,
        stance: EpistemicStance,
        expression: ExpressionStance = .neutral
    ) -> SelfExpressionAudit {
        SelfExpressionAudit(
            epistemicViolations: EpistemicDisclosure.violations(stance: stance, text: text),
            expressionViolations: ExpressionPolicy.violations(stance: expression, text: text)
        )
    }
}

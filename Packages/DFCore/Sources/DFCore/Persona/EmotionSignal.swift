import Foundation

// MARK: - 情绪数据源（D37）
//
// 目标：给编排器与界面一个确定、可解释的"当前情绪"，而不是靠模型自述。
//
// 口径：
// - 纯规则：只按用户这一轮的原话匹配线索词，不做模型推断、不联网；
// - 同一输入永远得到同一结果（可测、可回放）；
// - 没有线索时**衰减**回平静，而不是一直停留在上一个情绪；
// - 情绪只影响语气（见 `EmotionGuidance.directive`），不改变任何事实与业务判断。

extension EmotionKind {
    /// 由持久化的表情码反推情绪（读取 `character_states.mood_code` 时使用）。
    /// 困倦与中性都归到平静：它们表达的是"少话"，不是负面情绪。
    public init(mood: CharacterMood) {
        switch mood {
        case .neutral, .calm, .sleepy: self = .calm
        case .warm: self = .warm
        case .joyful: self = .joyful
        case .sad: self = .sad
        case .anxious: self = .anxious
        case .annoyed: self = .annoyed
        case .excited: self = .excited
        }
    }
}

public enum EmotionSignal {
    /// 每轮无新线索时的衰减步长
    public static let decayStep = 0.2
    /// 低于该强度直接回到平静，避免长期停在"微弱不满"上
    public static let lowWatermark = 0.2

    /// 用户在表达难受、疲惫、压力
    public static let distressMarkers = [
        "难过", "伤心", "想哭", "哭了", "很累", "好累", "累死", "压力",
        "焦虑", "失眠", "崩溃", "委屈", "不开心", "心情不好", "撑不住"
    ]

    /// 用户在表达亲近与感谢
    public static let affectionMarkers = [
        "想你", "喜欢你", "爱你", "抱抱", "谢谢", "陪我", "辛苦了"
    ]

    /// 用户心情不错
    public static let joyMarkers = [
        "开心", "太好了", "哈哈", "嘿嘿", "成功", "搞定", "顺利", "好消息", "值得高兴"
    ]

    /// 用户语气着急或不满
    public static let urgencyMarkers = [
        "快点", "赶紧", "怎么还没", "为什么不", "急死", "马上", "等很久"
    ]

    /// 由一轮对话推断情绪。
    ///
    /// 优先级：难受 > 亲近 > 开心 > 着急 > 衰减/平静。
    /// 优先级是刻意的：用户说"虽然很难过但还是谢谢你"时，应当先照顾难受。
    public static func infer(
        userText: String,
        assistantText: String = "",
        previous: EmotionState? = nil
    ) -> EmotionState {
        let text = userText.lowercased()

        if contains(text, anyOf: distressMarkers) {
            return EmotionState(kind: .warm, intensity: 0.7, reason: "用户在表达难受或疲惫")
        }
        if contains(text, anyOf: affectionMarkers) {
            return EmotionState(kind: .warm, intensity: 0.75, reason: "用户在表达亲近")
        }
        if contains(text, anyOf: joyMarkers) {
            return EmotionState(kind: .joyful, intensity: 0.65, reason: "用户心情不错")
        }
        if contains(text, anyOf: urgencyMarkers) {
            return EmotionState(kind: .anxious, intensity: 0.45, reason: "用户语气比较急")
        }

        // 没有线索：自然回落，不凭空切换情绪
        guard let previous, previous.kind != .calm else {
            return EmotionState(kind: .calm, intensity: 0.3, reason: "这一轮没有明显的情绪线索")
        }
        let decayed = EmotionGuidance.clamp(previous.intensity - decayStep)
        guard decayed > lowWatermark else {
            return EmotionState(kind: .calm, intensity: 0.3, reason: "情绪已平复")
        }
        return EmotionState(kind: previous.kind, intensity: decayed, reason: "情绪自然回落")
    }

    private static func contains(_ text: String, anyOf markers: [String]) -> Bool {
        markers.contains { text.contains($0) }
    }
}

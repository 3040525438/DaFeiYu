import Foundation

// MARK: - 动态表情与互动动画（D36）
//
// 只做纯逻辑：情绪 → 表情码 / 动作 / 动画参数，以及生成状态 → 互动动画。
// 不加载图片资源、不驱动 SwiftUI，界面按这里的返回值渲染即可，便于在 CI 全量覆盖。
//
// 硬约束：
// - 数值一律夹取，上游越界不会导致动画失控；
// - 无随机、无隐式状态，同一输入永远得到同一结果（可测、可缓存）；
// - 尊重"减弱动态效果"：开启时动画时长归零、缩放归 1，不做位移。

/// 角色表情码，取值与 `character_states.mood_code` 对齐。
public enum CharacterMood: String, Sendable, Equatable, CaseIterable {
    case neutral
    case calm
    case warm
    case joyful
    case sad
    case anxious
    case annoyed
    case excited
    /// 低能量：困倦、少话
    case sleepy

    public var displayName: String {
        switch self {
        case .neutral: return "平静"
        case .calm: return "安静"
        case .warm: return "温和"
        case .joyful: return "开心"
        case .sad: return "低落"
        case .anxious: return "不安"
        case .annoyed: return "有点烦"
        case .excited: return "兴奋"
        case .sleepy: return "困倦"
        }
    }

    /// 未知值一律落到 `neutral`，避免历史脏数据导致界面空白
    public init(stored: String) {
        self = CharacterMood(rawValue: stored.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .neutral
    }

    /// 由 D37 的情绪状态派生表情（D37 的情绪数据源尚未接编排器，这里先打通映射）
    public init(emotion: EmotionKind) {
        switch emotion {
        case .calm: self = .calm
        case .warm: self = .warm
        case .joyful: self = .joyful
        case .sad: self = .sad
        case .anxious: self = .anxious
        case .annoyed: self = .annoyed
        case .excited: self = .excited
        }
    }

    /// 该表情是否属于"低唤醒"（动作应更小、更慢）
    public var isLowArousal: Bool {
        switch self {
        case .sleepy, .sad, .calm: return true
        default: return false
        }
    }

    /// 该表情是否属于"高唤醒"（允许更明显的动作）
    public var isHighArousal: Bool {
        switch self {
        case .excited, .joyful: return true
        default: return false
        }
    }
}

/// 角色动作
public enum CharacterAction: String, Sendable, Equatable, CaseIterable {
    case idle
    case nod
    case wave
    case think
    case rest

    public var displayName: String {
        switch self {
        case .idle: return "静立"
        case .nod: return "点头"
        case .wave: return "挥手"
        case .think: return "思考"
        case .rest: return "休息"
        }
    }
}

/// 动画参数（单位：秒 / 倍率），界面直接消费
public struct CharacterAnimation: Sendable, Equatable {
    public var duration: Double
    public var repeatCount: Int
    public var scale: Double
    /// 0–1 的动作幅度；0 表示只换表情不动
    public var intensity: Double

    public init(duration: Double, repeatCount: Int, scale: Double, intensity: Double) {
        self.duration = max(0, duration)
        self.repeatCount = max(0, repeatCount)
        self.scale = scale.isNaN ? 1 : max(0.5, min(scale, 1.5))
        self.intensity = intensity.isNaN ? 0 : max(0, min(intensity, 1))
    }

    /// 减弱动态效果下的静止版本
    public var reduced: CharacterAnimation {
        CharacterAnimation(duration: 0, repeatCount: 0, scale: 1, intensity: 0)
    }

    public var isAnimated: Bool {
        duration > 0 && repeatCount > 0 && intensity > 0
    }
}

/// 一次完整展示：表情 + 动作 + 动画
public struct CharacterPresentation: Sendable, Equatable {
    public var mood: CharacterMood
    public var action: CharacterAction
    public var animation: CharacterAnimation

    public init(mood: CharacterMood, action: CharacterAction, animation: CharacterAnimation) {
        self.mood = mood
        self.action = action
        self.animation = animation
    }
}

public enum CharacterPresentationPolicy {
    /// 能量低于该阈值时强制进入休息动作，不再挥手
    public static let exhaustionThreshold = 0.25
    /// 亲和低于该阈值时动作幅度减半（不主动亲近）
    public static let distantAffinityThreshold = 0.3

    public static func clamp(_ value: Double) -> Double {
        guard !value.isNaN else { return 0.5 }
        return max(0, min(value, 1))
    }

    /// 由角色状态生成展示参数。
    /// - Parameters:
    ///   - energy: 精力 0–1（越界夹取）
    ///   - affinity: 亲和 0–1（越界夹取）
    ///   - reduceMotion: 系统"减弱动态效果"
    public static func make(
        mood: CharacterMood,
        energy: Double,
        affinity: Double,
        reduceMotion: Bool = false
    ) -> CharacterPresentation {
        let energy = clamp(energy)
        let affinity = clamp(affinity)

        // 1. 动作：先看能量是否耗尽，再看唤醒度
        let action: CharacterAction
        if energy < exhaustionThreshold {
            action = .rest
        } else if mood.isHighArousal {
            action = .wave
        } else if mood == .anxious {
            action = .think
        } else if mood.isLowArousal {
            action = .idle
        } else {
            action = .nod
        }

        // 2. 基线与幅度：高唤醒更明显，低唤醒更克制；能量线性缩放
        let baseDuration: Double
        let baseRepeat: Int
        let baseScale: Double
        switch action {
        case .rest:
            baseDuration = 3.2; baseRepeat = 1; baseScale = 1.0
        case .idle:
            baseDuration = 2.4; baseRepeat = 1; baseScale = 1.0
        case .nod:
            baseDuration = 0.6; baseRepeat = 2; baseScale = 1.02
        case .think:
            baseDuration = 1.4; baseRepeat = 2; baseScale = 1.0
        case .wave:
            baseDuration = 0.8; baseRepeat = 2; baseScale = 1.04
        }

        var intensity = energy * (mood.isHighArousal ? 1.0 : 0.7)
        if affinity < distantAffinityThreshold {
            intensity *= 0.5
        }
        intensity = clamp(intensity)

        let animation = CharacterAnimation(
            duration: baseDuration,
            // 幅度太低就不要重复播放，避免"抖动"
            repeatCount: intensity < 0.15 ? 1 : baseRepeat,
            scale: baseScale,
            intensity: intensity
        )

        return CharacterPresentation(
            mood: mood,
            action: action,
            animation: reduceMotion ? animation.reduced : animation
        )
    }

    /// 从持久化状态行直接生成（供 Repository / 界面复用）
    public static func make(
        moodCode: String,
        energy: Double,
        affinity: Double,
        reduceMotion: Bool = false
    ) -> CharacterPresentation {
        make(
            mood: CharacterMood(stored: moodCode),
            energy: energy,
            affinity: affinity,
            reduceMotion: reduceMotion
        )
    }
}

// MARK: - 互动动画

/// 互动动画：与 `ChatTurnPhase` 一一对应，不引入新的界面状态。
public enum InteractionAnimation: String, Sendable, Equatable, CaseIterable {
    /// 无进行中轮次：待机呼吸
    case breathing
    /// 等待（已提交、未开组）：轻微头像脉冲
    case pulsing
    /// 思考：点状省略
    case thinking
    /// 生成：打字光标
    case typing
    /// 暂停：光标闪烁变慢
    case paused
    /// 完成：一次轻微弹跳
    case settle
    /// 失败：一次左右轻晃（不夸张）
    case shake
    /// 停止：回到待机，不播放强调动画
    case fading

    public var displayName: String {
        switch self {
        case .breathing: return "待机"
        case .pulsing: return "等待"
        case .thinking: return "思考"
        case .typing: return "生成中"
        case .paused: return "暂停"
        case .settle: return "完成"
        case .shake: return "失败"
        case .fading: return "停止"
        }
    }

    /// 是否循环播放（进行中才循环，终态只播一次）
    public var loops: Bool {
        switch self {
        case .breathing, .pulsing, .thinking, .typing, .paused: return true
        case .settle, .shake, .fading: return false
        }
    }
}

public enum InteractionAnimationPolicy {
    public static func animation(for phase: ChatTurnPhase) -> InteractionAnimation {
        switch phase {
        case .idle: return .breathing
        case .waiting: return .pulsing
        case .thinking: return .thinking
        case .generating: return .typing
        case .paused: return .paused
        case .completed: return .settle
        case .failed: return .shake
        case .stopped: return .fading
        }
    }

    /// 循环时长（秒）；终态返回一次性时长
    public static func duration(for animation: InteractionAnimation) -> Double {
        switch animation {
        case .breathing: return 3.0
        case .pulsing: return 1.2
        case .thinking: return 0.9
        case .typing: return 0.6
        case .paused: return 1.8
        case .settle: return 0.35
        case .shake: return 0.3
        case .fading: return 0.5
        }
    }
}

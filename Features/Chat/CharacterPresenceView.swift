import SwiftUI
import DFCore

/// 角色在场（D36）：把 `CharacterStateService` 的状态与 `ChatTurnPhase`
/// 渲染成一个会呼吸、会点头、会思考的小头像。
///
/// 只消费 `DFCore` 的纯策略结果（表情/动作/动画参数、互动动画），
/// 不自己做情绪判断，也不依赖任何图片资源：资源缺失时仍能显示表情色点与动作语义。
@MainActor
struct CharacterPresenceView: View {
    let container: AppContainer
    let phase: ChatTurnPhase
    var size: CGFloat = 28

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presentation: CharacterPresentation?
    /// 终态一次性强调（完成/失败/停止），循环动画不在这里
    @State private var oneShot = false

    private var interaction: InteractionAnimation {
        InteractionAnimationPolicy.animation(for: phase)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !interaction.loops)) { context in
            mark(pulse: wave(at: context.date))
        }
        .task { await reload() }
        .onChange(of: phase) { _, newValue in
            Task { await reload() }
            playOneShot(for: newValue)
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - 渲染

    private func mark(pulse: Double) -> some View {
        DFCharacterMark(size: size)
            .scaleEffect(scale(pulse: pulse))
            .opacity(opacity)
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(moodTint)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(DFColor.canvas, lineWidth: 1.5))
            }
    }

    private var opacity: Double {
        guard let presentation else { return 1 }
        // 低唤醒/休息时整体更"安静"，但不至于看不见
        switch presentation.action {
        case .rest: return 0.7
        case .idle: return 0.88
        default: return 1
        }
    }

    private func scale(pulse: Double) -> CGFloat {
        guard let presentation else { return 1 }
        guard !reduceMotion else { return 1 }
        // 幅度来自策略层（已夹取 0–1），精力低或亲和低时动作自然变小
        let amplitude = 0.05 * presentation.animation.intensity
        var value = 1 + amplitude * pulse
        if oneShot { value += 0.06 }
        return CGFloat(value)
    }

    /// 循环动画的相位：-1…1；不循环或减弱动态效果时恒为 0
    private func wave(at date: Date) -> Double {
        guard interaction.loops, !reduceMotion else { return 0 }
        let duration = max(InteractionAnimationPolicy.duration(for: interaction), 0.2)
        let progress = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: duration) / duration
        return sin(progress * 2 * .pi)
    }

    /// 终态只播一次，时长与策略层一致，最长不超过 0.5 秒
    private func playOneShot(for phase: ChatTurnPhase) {
        guard !reduceMotion else { return }
        let animation = InteractionAnimationPolicy.animation(for: phase)
        guard !animation.loops else { return }
        let duration = InteractionAnimationPolicy.duration(for: animation)
        withAnimation(.easeOut(duration: duration)) { oneShot = true }
        withAnimation(.easeInOut(duration: duration).delay(duration)) { oneShot = false }
    }

    private var moodTint: Color {
        guard let mood = presentation?.mood else { return DFColor.success }
        switch mood {
        case .joyful, .excited: return DFColor.warning
        case .warm, .calm: return DFColor.success
        case .sad: return DFColor.primaryDeep
        case .anxious: return DFColor.lilac
        case .annoyed: return DFColor.danger
        case .sleepy, .neutral: return DFColor.inkMuted
        }
    }

    private var accessibilityLabel: String {
        guard let presentation else { return "大肥鱼" }
        return "大肥鱼，\(presentation.mood.displayName)，\(presentation.action.displayName)，\(interaction.displayName)"
    }

    // MARK: - 数据

    private func reload() async {
        guard let id = try? await container.characters.activeCharacterID(),
              let state = try? await container.characterStates.state(for: id) else { return }
        presentation = state.presentation(reduceMotion: reduceMotion)
    }
}

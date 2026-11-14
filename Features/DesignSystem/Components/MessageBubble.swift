import SwiftUI
import DFCore

/// 消息气泡：只负责外观，不持有业务状态。
/// 己方使用品牌渐变，对方使用 surface + 1px 描边 + 向下柔和阴影。
/// W2-7：气泡样式 / 字号 / 暗色背景都来自 `ChatTheme`，不再写死。
struct MessageBubble: View {
    enum Kind {
        case me
        case other
    }

    let text: String
    let kind: Kind
    var isFailed: Bool = false
    var isStreaming: Bool = false
    var theme: ChatTheme = .default

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var caretVisible = true

    private var isDark: Bool { theme.background == "dark" }
    private var isPlain: Bool { theme.bubbleStyle == "plain" }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: DFRadius.bubble,
            bottomLeadingRadius: kind == .me ? DFRadius.bubble : DFRadius.bubbleTail,
            bottomTrailingRadius: kind == .me ? DFRadius.bubbleTail : DFRadius.bubble,
            topTrailingRadius: DFRadius.bubble,
            style: .continuous
        )
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            Text(text)
                .font(.system(size: 15 * theme.fontScale))
                .foregroundStyle(textColor)
                .lineSpacing(2)
                .multilineTextAlignment(.leading)

            if isStreaming {
                caret
            }
        }
        .padding(.horizontal, isPlain ? 2 : 12)
        .padding(.vertical, isPlain ? 2 : 9)
        .background(bubbleBackground)
        .clipShape(shape)
        .overlay {
            if isFailed {
                shape.stroke(DFColor.warmHairline, lineWidth: 1)
            }
        }
        .shadow(
            color: (isFailed || isPlain) ? .clear : DFShadow.cardColor,
            radius: DFShadow.cardRadius,
            x: 0,
            y: DFShadow.cardY
        )
        .opacity(isFailed ? 0.72 : 1)
    }

    private var textColor: Color {
        if kind == .me { return .white }
        return isDark ? Color(white: 0.93) : DFColor.ink
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if isPlain {
            Color.clear
        } else if kind == .me {
            if isDark {
                Color(red: 0.24, green: 0.36, blue: 0.48)
            } else {
                DFColor.bubbleMe
            }
        } else {
            isDark ? Color(white: 0.16) : DFColor.bubbleOther
        }
    }

    /// 流式输出光标：2pt 竖线闪烁，不用省略号
    private var caret: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(kind == .me ? Color.white : DFColor.primary)
            .frame(width: 2, height: 13)
            .padding(.leading, 1)
            .opacity(caretVisible ? 1 : 0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(DFMotion.caretBlink) {
                    caretVisible = false
                }
            }
    }
}

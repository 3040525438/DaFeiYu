import SwiftUI

/// 发送失败徽标：红色感叹号。
/// 视觉尺寸 17pt，外层由调用方提供可点击区域；点击即重发同一条消息。
struct FailedBadge: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(DFColor.danger)
            Text("!")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.white)
        }
        .frame(width: 17, height: 17)
        .shadow(color: DFColor.dangerSoft, radius: 3)
        .accessibilityHidden(true)
    }
}

/// 失败态可点击行：红色感叹号 + 灰色提示。
/// 整行可点，热区不低于 32pt；VoiceOver 会朗读「发送失败，双击重发」。
struct FailedRetryRow: View {
    let onRetry: () -> Void

    var body: some View {
        Button(action: onRetry) {
            HStack(spacing: 5) {
                FailedBadge()
                Text("点按重发")
                    .font(.system(size: 10))
                    .foregroundStyle(DFColor.inkMuted)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("发送失败")
        .accessibilityHint("双击重发这条消息")
    }
}

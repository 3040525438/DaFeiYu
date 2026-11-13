import SwiftUI

/// 主动行为：从空间页进入的二级页。
/// 第一阶段尚无主动消息与待确认记忆的数据来源，这里只解释规则，不放假开关。
@MainActor
struct ProactiveView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                emptyCard
                ruleCard
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(alignment: .top) { pageBackground }
        .navigationTitle("主动行为")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(DFColor.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private var emptyCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 22))
                .foregroundStyle(DFColor.lilac)

            Text("主动行为还没有开启")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DFColor.ink)

            Text("这一版不会主动发消息。等阶段二接入主动思考与记忆确认后，这里会出现她的想法、近期活动与待确认记忆。")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.inkMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 26)
        .background(
            RoundedRectangle(cornerRadius: DFRadius.panel, style: .continuous)
                .fill(DFColor.lilacSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.panel, style: .continuous)
                .strokeBorder(
                    DFColor.lilac.opacity(0.45),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
    }

    private var ruleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("她主动找你之前，会先过三件事")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DFColor.ink)

            rule(index: "01", title: "在你允许的时段", detail: "免打扰时间内不主动发消息，醒来后也不会补发一串。")
            rule(index: "02", title: "有明确的理由", detail: "每次主动都会记录触发原因，你可以在活动里回看。")
            rule(index: "03", title: "随时可以关掉", detail: "开关只有一处，关掉后不再主动，也不会偷偷改成常开。")
        }
        .padding(16)
        .background(DFColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous)
                .stroke(DFColor.hairline, lineWidth: 1)
        )
    }

    private func rule(index: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(index)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DFColor.primary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(DFColor.ink)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(DFColor.inkMuted)
                    .lineSpacing(2)
            }
        }
    }

    private var pageBackground: some View {
        ZStack(alignment: .top) {
            DFColor.canvas
            DFSoftGlow()
                .frame(height: 220)
                .clipped()
        }
        .ignoresSafeArea()
    }
}

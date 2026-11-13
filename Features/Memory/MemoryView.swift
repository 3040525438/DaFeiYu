import SwiftUI
import DFCore

/// 记忆页：共同回忆档案。
/// 第一阶段没有独立的记忆表，因此只展示真实的对话量，记忆卡片等阶段二接入。
@MainActor
struct MemoryView: View {
    @EnvironmentObject private var container: AppContainer

    @State private var stats = CompanionStats()
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    archiveCover
                    statTiles

                    if isLoading {
                        ProgressView()
                            .tint(DFColor.primary)
                            .padding(.top, 24)
                    } else {
                        emptyCard
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 24)
            }
            .background(alignment: .top) { pageBackground }
            .navigationTitle("记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DFColor.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .task {
            stats = await CompanionStats.load(container: container)
            isLoading = false
        }
    }

    // MARK: - 档案封面

    private var archiveCover: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: DFRadius.panel, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            DFColor.primary.opacity(0.22),
                            DFColor.lilac.opacity(0.24),
                            DFColor.accentPink.opacity(0.20)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            DFScaleBackdrop(opacity: 0.12)
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.panel, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("共同回忆档案")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(DFColor.primaryDeep)

                Text("\(stats.messageCount)")
                    .font(DFFont.number)
                    .foregroundStyle(DFColor.ink)

                Text("条对话 · 从 \(CompanionStats.dateText(stats.startedAt)) 开始 · 一起走过 \(stats.dayCount) 天")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.inkMuted)
            }
            .padding(16)

            Text("已归档")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1)
                .foregroundStyle(DFColor.primaryDeep)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(DFColor.primary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                )
                .rotationEffect(.degrees(5))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: 126)
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.panel, style: .continuous)
                .stroke(DFColor.hairline, lineWidth: 1)
        )
    }

    // MARK: - 数据

    private var statTiles: some View {
        HStack(spacing: 8) {
            statTile(value: "\(stats.messageCount)", label: "对话消息")
            statTile(value: "\(stats.dayCount)", label: "陪伴天数")
            statTile(value: "0", label: "记忆条目")
        }
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(DFColor.ink)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(DFColor.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(DFColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(DFColor.hairline, lineWidth: 1)
        )
    }

    // MARK: - 空态

    private var emptyCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .font(.system(size: 22))
                .foregroundStyle(DFColor.lilac)

            Text("记忆库还是空的")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DFColor.ink)

            Text("这一版只保存原始对话。等阶段二导入 AstrBot 的记忆与日记后，这里会出现置顶回忆、图片与时间线。")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.inkMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .background(DFColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous)
                .stroke(DFColor.hairline, lineWidth: 1)
        )
    }

    private var pageBackground: some View {
        ZStack(alignment: .top) {
            DFColor.canvas
            DFSoftGlow()
                .frame(height: 240)
                .clipped()
            DFScaleBackdrop(opacity: 0.14)
                .frame(height: 170)
        }
        .ignoresSafeArea()
    }
}

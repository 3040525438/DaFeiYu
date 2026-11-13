import SwiftUI
import DFCore

/// 个人空间：以角色为视觉中心，下面是人格与陪伴的真实信息。
/// 角色形象仍是占位（DFCharacterMark），后续换资源不影响布局。
@MainActor
struct SpaceView: View {
    @EnvironmentObject private var container: AppContainer
    @Binding var selection: Int

    @State private var stats = CompanionStats()
    @State private var persona: Persona?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    stage
                    profileCard
                    actions
                    footnote
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 24)
            }
            .background(alignment: .top) { pageBackground }
            .navigationTitle("空间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DFColor.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .task {
            stats = await CompanionStats.load(container: container)
            if let loaded = try? await container.personas.corePersona() {
                persona = loaded
            }
            isLoading = false
        }
    }

    // MARK: - 角色舞台

    private var stage: some View {
        ZStack {
            LinearGradient(
                colors: [
                    DFColor.primary.opacity(0.24),
                    DFColor.lilac.opacity(0.26),
                    DFColor.accentPink.opacity(0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            DFScaleBackdrop(opacity: 0.16)

            Circle()
                .fill(DFColor.surface.opacity(0.55))
                .frame(width: 168, height: 168)
                .blur(radius: 26)

            DFCharacterMark(size: isLoading ? 78 : 92)
                .shadow(color: DFColor.primary.opacity(0.22), radius: 18, y: 10)

            VStack {
                Spacer()
                HStack {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(DFColor.success)
                            .frame(width: 5, height: 5)
                        Text("此刻 · 安静待机")
                            .font(.system(size: 10))
                            .foregroundStyle(DFColor.ink)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(DFColor.surface.opacity(0.78), in: Capsule())

                    Spacer()

                    Text("第 \(stats.dayCount) 天")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DFColor.inkMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(DFColor.surface.opacity(0.7), in: Capsule())
                }
                .padding(12)
            }
        }
        .frame(height: 236)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.panel, style: .continuous)
                .stroke(DFColor.hairline, lineWidth: 1)
        )
    }

    // MARK: - 档案

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(persona?.name ?? "大肥鱼")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(DFColor.ink)

                Text("v\(persona?.currentVersion ?? 1)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DFColor.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(DFColor.primarySoft, in: Capsule())

                Spacer()

                Text(persona == nil ? "加载中" : "核心人格 · 已锁定")
                    .font(.system(size: 10))
                    .foregroundStyle(DFColor.inkMuted)
            }

            Text("本地存储 · 不上传 · 只有你和她")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.inkMuted)

            HStack(spacing: 8) {
                miniStat(value: "\(stats.dayCount)", label: "陪伴天数")
                miniStat(value: "\(stats.messageCount)", label: "共同消息")
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(DFColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.panel, style: .continuous)
                .stroke(DFColor.hairline, lineWidth: 1)
        )
    }

    private func miniStat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(DFColor.ink)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(DFColor.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(DFColor.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 入口

    private var actions: some View {
        VStack(spacing: 8) {
            NavigationLink {
                ProactiveView()
            } label: {
                actionRow(
                    icon: "sparkles",
                    title: "主动行为",
                    detail: "她会自己想起你，也会先征求你的同意"
                )
            }
            .buttonStyle(.plain)

            Button {
                selection = 4
            } label: {
                actionRow(
                    icon: "slider.horizontal.3",
                    title: "模型与接口",
                    detail: "在设置里配置模型、密钥与语音"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func actionRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(DFColor.primarySoft)
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundStyle(DFColor.primary)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DFColor.ink)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(DFColor.inkMuted)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DFColor.inkMuted.opacity(0.6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(DFColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous)
                .stroke(DFColor.hairline, lineWidth: 1)
        )
    }

    private var footnote: some View {
        Text("角色形象为占位插画，替换资源后布局不变")
            .font(.system(size: 9))
            .foregroundStyle(DFColor.inkMuted.opacity(0.8))
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
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

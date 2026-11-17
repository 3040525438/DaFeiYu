import SwiftUI
import Foundation
import DFCore
import DFData

/// 成长页：陪伴天数与真实消息统计。
/// 阶段一不生成亲密度、阶段总结这类派生指标，避免出现没有依据的数字。
@MainActor
struct GrowthView: View {
    @EnvironmentObject private var container: AppContainer

    @State private var stats = CompanionStats()
    @State private var isLoading = true
    /// D32：自我反思的真实记录 + 手动触发状态
    @State private var reflections: [ReflectionRecord] = []
    @State private var isReflecting = false
    @State private var reflectMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    hero
                    statRow

                    if isLoading {
                        ProgressView()
                            .tint(DFColor.primary)
                            .padding(.top, 20)
                    } else {
                        emptyCard
                        reflectionSection
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 24)
            }
            .background(alignment: .top) { pageBackground }
            .navigationTitle("成长")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DFColor.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .task {
            stats = await CompanionStats.load(container: container)
            isLoading = false
            await loadReflections()
        }
    }

    // MARK: - 自我反思（D32）

    private var reflectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(DFColor.primaryDeep)
                Text("自我反思")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DFColor.ink)
                Spacer()
                Button {
                    Task { await reflectNow() }
                } label: {
                    Text(isReflecting ? "反思中…" : "现在反思一次")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .disabled(isReflecting)
            }

            if let reflectMessage {
                Text(reflectMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(DFColor.inkMuted)
            }

            if reflections.isEmpty {
                Text("还没有反思记录。她需要至少 3 条真实记忆才会开始反思，绝不会凭空编造。")
                    .font(.system(size: 11))
                    .foregroundStyle(DFColor.inkMuted)
                    .lineSpacing(2)
            } else {
                ForEach(reflections.prefix(5)) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.conclusion.isEmpty ? item.content : item.conclusion)
                            .font(.system(size: 12))
                            .foregroundStyle(DFColor.ink)
                        HStack(spacing: 6) {
                            Text(item.epistemicStatus == "observed" ? "观察" : "推断")
                                .font(.system(size: 9))
                                .foregroundStyle(DFColor.inkMuted)
                            Text("可信度 \(Int(item.confidence * 100))%")
                                .font(.system(size: 9))
                                .foregroundStyle(DFColor.inkMuted)
                            Spacer()
                            Text(Self.reflectionTime(item.createdAt))
                                .font(.system(size: 9))
                                .foregroundStyle(DFColor.inkMuted)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DFColor.surfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DFColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous)
                .stroke(DFColor.hairline, lineWidth: 1)
        )
    }

    private func loadReflections() async {
        reflections = (try? await container.reflections.recent(limit: 20)) ?? []
    }

    private func reflectNow() async {
        isReflecting = true
        defer { isReflecting = false }
        do {
            let count = try await container.runReflectionNow()
            reflectMessage = count > 0
                ? "本次写入 \(count) 条反思结论"
                : "素材不足或没有值得反思的内容，本次没有写入"
            await loadReflections()
        } catch {
            reflectMessage = "反思失败：\(error.localizedDescription)"
        }
    }

    private static func reflectionTime(_ millis: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000))
    }

    private var hero: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: DFRadius.panel, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            DFColor.lilac.opacity(0.26),
                            DFColor.primary.opacity(0.18)
                        ],
                        startPoint: .topTrailing,
                        endPoint: .bottomLeading
                    )
                )

            DFScaleBackdrop(opacity: 0.10)
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.panel, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DFColor.primary)
                    Text("已经一起走过")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(DFColor.primaryDeep)
                }

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(stats.dayCount)")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(DFColor.ink)
                        .monospacedDigit()
                    Text("天")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DFColor.inkMuted)
                }

                Text("从 \(CompanionStats.dateText(stats.startedAt)) 开始 · 平均每天 \(averagePerDay) 条消息")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.inkMuted)
            }
            .padding(16)
        }
        .frame(height: 132)
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.panel, style: .continuous)
                .stroke(DFColor.hairline, lineWidth: 1)
        )
    }

    private var statRow: some View {
        HStack(spacing: 8) {
            statTile(value: "\(stats.messageCount)", label: "消息总数")
            statTile(value: CompanionStats.dateText(stats.lastMessageAt), label: "最近对话", small: true)
        }
    }

    private func statTile(value: String, label: String, small: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: small ? 13 : 18, weight: .bold))
                .foregroundStyle(DFColor.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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

    private var emptyCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 22))
                .foregroundStyle(DFColor.primary)

            Text("还没有形成阶段总结")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DFColor.ink)

            Text("成长轨迹来自长期对话。等记录积累到一定量，这里会出现阶段回顾、她学会的事和时间线。")
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

    private var averagePerDay: String {
        let average = Double(stats.messageCount) / Double(max(stats.dayCount, 1))
        return String(format: "%.1f", average)
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

import SwiftUI
import DFCore

/// D31：关系回顾（五类独立视图）。
///
/// 只做「回顾」：档案、阶段历程、共同经历、重要转折、纪念日全部来自
/// `RelationshipService`，这里不生成、不推断任何关系内容；
/// 阶段提案的确认仍在审批中心完成，本页只提示有几条待确认。
@MainActor
struct RelationshipCenterView: View {
    @EnvironmentObject private var container: AppContainer

    @State private var overview: RelationshipOverview?
    @State private var section: RelationshipViewSection = .overview
    @State private var isLoading = true
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                sectionPicker

                if isLoading {
                    ProgressView("读取关系记录…")
                        .tint(DFColor.primary)
                        .padding(.top, 28)
                } else if let errorText {
                    noticeCard(errorText, tint: DFColor.danger)
                } else if let overview {
                    content(overview)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 24)
        }
        .background(DFColor.canvas)
        .navigationTitle("关系")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(DFColor.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task { await load() }
    }

    // MARK: - 数据

    private func load() async {
        isLoading = true
        errorText = nil
        do {
            // 容器与数据库都不是 Sendable，按顺序读取，避免跨隔离域传递
            let profile = try await container.relationships.profile()
            let milestones = try await container.relationships.milestones()
            let history = try await container.relationships.stageHistory(limit: 200)
            overview = RelationshipOverview.compose(
                profile: profile,
                milestones: milestones,
                stageChanges: history
            )
        } catch {
            errorText = ErrorDiagnoser.diagnose(error.localizedDescription).headline
            overview = nil
        }
        isLoading = false
    }

    // MARK: - 分类

    private var sectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(RelationshipViewSection.allCases, id: \.self) { item in
                    Button {
                        section = item
                    } label: {
                        Text(label(item))
                            .font(.system(size: 11, weight: section == item ? .semibold : .regular))
                            .foregroundStyle(section == item ? Color.white : DFColor.ink)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                section == item ? DFColor.primary : DFColor.surface,
                                in: Capsule()
                            )
                            .overlay(
                                Capsule()
                                    .stroke(
                                        section == item ? Color.clear : DFColor.hairline,
                                        lineWidth: 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 1)
            .padding(.vertical, 1)
        }
    }

    private func label(_ item: RelationshipViewSection) -> String {
        guard let overview else { return item.title }
        let count = overview.count(in: item)
        return count > 0 ? "\(item.title) \(count)" : item.title
    }

    @ViewBuilder
    private func content(_ overview: RelationshipOverview) -> some View {
        switch section {
        case .overview:
            profileCard(overview)
        case .stageHistory:
            stageHistorySection(overview)
        case .sharedExperience, .turningPoint, .anniversary:
            milestoneSection(
                overview.milestones(in: section),
                hint: overview.emptyHint(in: section)
            )
        }
    }

    // MARK: - 概览

    private func profileCard(_ overview: RelationshipOverview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(overview.partnerNameText)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(DFColor.ink)

                Text(overview.stageText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(overview.isStageUnset ? DFColor.inkMuted : DFColor.primaryDeep)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        overview.isStageUnset ? DFColor.surfaceAlt : DFColor.primarySoft,
                        in: Capsule()
                    )

                Spacer()
            }

            HStack(spacing: 4) {
                Text("亲密度")
                    .font(.system(size: 10))
                    .foregroundStyle(DFColor.inkMuted)
                Text(overview.closenessText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DFColor.ink)
                    .monospacedDigit()
                Spacer()
                Text("自 \(overview.stageSinceText)")
                    .font(.system(size: 10))
                    .foregroundStyle(DFColor.inkMuted)
            }

            closenessBar(overview.closeness)

            Text(overview.summaryText)
                .font(DFFont.caption)
                .foregroundStyle(DFColor.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            if overview.isStageUnset {
                noticeCard("关系阶段还没设定。她只能提案，确认后才生效。", tint: DFColor.warning)
            }

            if overview.pendingProposalCount > 0 {
                noticeCard(
                    "有 \(overview.pendingProposalCount) 条阶段提案等你在审批中心确认",
                    tint: DFColor.primary
                )
            }

            statTiles(overview)
        }
        .padding(14)
        .background(DFColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.panel, style: .continuous)
                .stroke(DFColor.hairline, lineWidth: 1)
        )
    }

    private func closenessBar(_ value: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DFColor.surfaceAlt)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [DFColor.primary, DFColor.lilac],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, geometry.size.width * value))
            }
        }
        .frame(height: 6)
    }

    private func statTiles(_ overview: RelationshipOverview) -> some View {
        HStack(spacing: 8) {
            statTile(value: "\(overview.sharedExperience.count)", label: "共同经历")
            statTile(value: "\(overview.turningPoint.count)", label: "重要转折")
            statTile(value: "\(overview.anniversary.count)", label: "纪念日")
            statTile(value: "\(overview.otherMilestones.count)", label: "其他记录")
        }
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(DFColor.ink)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(DFColor.inkMuted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(DFColor.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 阶段历程

    private func stageHistorySection(_ overview: RelationshipOverview) -> some View {
        VStack(spacing: 8) {
            if overview.stageHistory.isEmpty {
                emptyCard(overview.emptyHint(in: .stageHistory))
            } else {
                ForEach(overview.stageHistory) { entry in
                    stageRow(entry)
                }
            }
        }
    }

    private func stageRow(_ entry: RelationshipStageEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(entry.fromText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DFColor.inkMuted)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DFColor.inkMuted)
                Text(entry.toText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DFColor.ink)

                Spacer()

                Text(entry.statusText)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(statusColor(entry.isPending))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusColor(entry.isPending).opacity(0.14), in: Capsule())
            }

            Text(entry.reason)
                .font(.system(size: 11))
                .foregroundStyle(DFColor.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text(entry.proposerText)
                    .font(.system(size: 9))
                    .foregroundStyle(DFColor.inkMuted)
                Text("·")
                    .font(.system(size: 9))
                    .foregroundStyle(DFColor.inkMuted.opacity(0.6))
                Text(entry.timeText)
                    .font(.system(size: 9))
                    .foregroundStyle(DFColor.inkMuted)
                    .monospacedDigit()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DFColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous)
                .stroke(DFColor.hairline, lineWidth: 1)
        )
    }

    private func statusColor(_ isPending: Bool) -> Color {
        isPending ? DFColor.warning : DFColor.success
    }

    // MARK: - 里程碑

    private func milestoneSection(
        _ entries: [RelationshipTimelineEntry],
        hint: String
    ) -> some View {
        VStack(spacing: 8) {
            if entries.isEmpty {
                emptyCard(hint)
            } else {
                ForEach(entries) { entry in
                    milestoneRow(entry)
                }
            }
        }
    }

    private func milestoneRow(_ entry: RelationshipTimelineEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(entry.isHighlighted ? DFColor.primary : DFColor.lilac.opacity(0.55))
                .frame(width: 7, height: 7)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DFColor.ink)

                    if entry.isHighlighted {
                        Text(entry.importanceText)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(DFColor.primaryDeep)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(DFColor.primarySoft, in: Capsule())
                    }

                    Spacer()
                }

                if !entry.summary.isEmpty {
                    Text(entry.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(DFColor.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 6) {
                    Text(entry.dateText)
                        .font(.system(size: 9))
                        .foregroundStyle(DFColor.inkMuted)
                        .monospacedDigit()
                    Text("·")
                        .font(.system(size: 9))
                        .foregroundStyle(DFColor.inkMuted.opacity(0.6))
                    Text(entry.sourceText)
                        .font(.system(size: 9))
                        .foregroundStyle(DFColor.inkMuted)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DFColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous)
                .stroke(DFColor.hairline, lineWidth: 1)
        )
    }

    // MARK: - 通用卡片

    private func emptyCard(_ hint: String) -> some View {
        Text(hint)
            .font(DFFont.caption)
            .foregroundStyle(DFColor.inkMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(DFColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous)
                    .stroke(DFColor.hairline, lineWidth: 1)
            )
    }

    private func noticeCard(_ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(DFColor.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

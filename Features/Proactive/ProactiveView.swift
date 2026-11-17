import SwiftUI
import DFCore

/// 主动行为：真实治理页（D50 / D62 / D13）。
///
/// 两个分页：
/// - 主动消息：她计划过、发过或被闸门拦下的每一条，可收藏、减少类似、删除、看触发原因；
/// - 自主记录：`autonomy_runs` 的放行/拦截留痕，用来解释"为什么这次没主动"。
///
/// 没有数据时如实说明"还没有"，不放假开关、不假装链路已跑通。
@MainActor
struct ProactiveView: View {
    @EnvironmentObject private var container: AppContainer

    @State private var tab: Tab = .messages
    @State private var messages: [ProactiveMessage] = []
    @State private var runs: [AutonomyRun] = []
    @State private var includeDeleted = false
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var message: String?
    @State private var explanationRoute: ExplanationRoute?

    enum Tab: String, CaseIterable {
        case messages
        case runs

        var title: String {
            switch self {
            case .messages: return "主动消息"
            case .runs: return "自主记录"
            }
        }
    }

    /// 触发原因弹窗的路由包装：`ProactiveMessageExplanation` 没有 id，不能直接给 sheet(item:)
    struct ExplanationRoute: Identifiable {
        let id = UUID()
        let value: ProactiveMessageExplanation
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Picker("分页", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: tab) { _, _ in
                    Task { await reload() }
                }

                if let message {
                    banner(message, color: DFColor.primaryDeep)
                }
                if let errorText {
                    banner("读取失败：\(errorText)", color: DFColor.danger)
                }

                if isLoading {
                    ProgressView().tint(DFColor.primary).padding(.top, 24)
                } else {
                    switch tab {
                    case .messages:
                        messagesSection
                    case .runs:
                        runsSection
                    }
                    ruleCard
                }
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task { await reload() }
        .sheet(item: $explanationRoute) { route in
            NavigationStack {
                ProactiveExplanationView(explanation: route.value)
            }
        }
    }

    // MARK: - 主动消息

    @ViewBuilder
    private var messagesSection: some View {
        HStack {
            Text("共 \(messages.count) 条")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.inkMuted)
            Spacer()
            Toggle("含已删除", isOn: $includeDeleted)
                .font(.system(size: 11))
                .fixedSize()
                .onChange(of: includeDeleted) { _, _ in
                    Task { await reload() }
                }
        }

        if messages.isEmpty {
            emptyCard(
                icon: "sparkles",
                title: "还没有主动消息",
                detail: "她主动找你之前会先过发送闸门；如果一直没有，可以在「自主记录」里看是被哪一条规则拦下的。"
            )
        } else {
            ForEach(messages) { item in
                messageCard(item)
            }
        }
    }

    private func messageCard(_ item: ProactiveMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                tag(statusTitle(item.status), color: statusColor(item.status))
                if item.isFavorite {
                    tag("已收藏", color: DFColor.warning)
                }
                Spacer()
                Text(Self.timeText(item.plannedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(DFColor.inkMuted)
            }

            Text(item.text)
                .font(.system(size: 13))
                .foregroundStyle(DFColor.ink)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let reason = item.suppressReason, !reason.isEmpty {
                Text("未发出：\(reason)")
                    .font(.system(size: 10))
                    .foregroundStyle(DFColor.inkMuted)
            }

            HStack(spacing: 8) {
                Button {
                    Task { await showExplanation(item) }
                } label: {
                    chip("触发原因", icon: "questionmark.circle")
                }
                .buttonStyle(.plain)

                Button {
                    Task { await toggleFavorite(item) }
                } label: {
                    chip(item.isFavorite ? "取消收藏" : "收藏", icon: item.isFavorite ? "star.slash" : "star")
                }
                .buttonStyle(.plain)

                Button {
                    Task { await markNotInterested(item) }
                } label: {
                    chip("不感兴趣", icon: "hand.raised")
                }
                .buttonStyle(.plain)
                .disabled(item.feedback == .notInterested)

                Spacer()

                if item.status != .deleted {
                    Button {
                        Task { await remove(item) }
                    } label: {
                        chip("删除", icon: "trash")
                            .foregroundStyle(DFColor.danger)
                    }
                    .buttonStyle(.plain)
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

    // MARK: - 自主记录

    @ViewBuilder
    private var runsSection: some View {
        if runs.isEmpty {
            emptyCard(
                icon: "clock.badge.questionmark",
                title: "还没有自主记录",
                detail: "每次闸门判断都会留一条记录（放行或拦截）。主动行为开始运行后，这里能看到原因与耗时。"
            )
        } else {
            ForEach(runs) { run in
                runCard(run)
            }
        }
    }

    private func runCard(_ run: AutonomyRun) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                tag(run.kind, color: DFColor.primaryDeep)
                tag(run.status.rawValue, color: run.blockReason == nil ? DFColor.success : DFColor.warning)
                Spacer()
                Text(Self.timeText(run.startedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(DFColor.inkMuted)
            }

            if let decision = run.decision, !decision.isEmpty {
                Text("结论：\(decision)")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.inkMuted)
            }
            if let blockReason = run.blockReason, !blockReason.isEmpty {
                Text("拦截原因：\(blockReason)")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.inkMuted)
            }
            if let error = run.error, !error.isEmpty {
                Text("错误：\(error)")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.danger)
            }
            Text("来源：\(run.trigger)")
                .font(.system(size: 9))
                .foregroundStyle(DFColor.inkMuted.opacity(0.8))
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

    // MARK: - 规则说明

    private var ruleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("她主动找你之前，会先过三件事")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DFColor.ink)

            rule(index: "01", title: "在你允许的时段", detail: "免打扰时间内不主动发消息，醒来后也不会补发一串。")
            rule(index: "02", title: "有明确的理由", detail: "每次主动都会记录触发原因，你可以在这里回看。")
            rule(index: "03", title: "随时可以关掉", detail: "总开关在「设置 → 通知 → 主动行为与通知」，关掉后不再主动。")
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

    private func emptyCard(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(DFColor.lilac)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DFColor.ink)
            Text(detail)
                .font(DFFont.caption)
                .foregroundStyle(DFColor.inkMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
        .background(DFColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous)
                .stroke(DFColor.hairline, lineWidth: 1)
        )
    }

    private func banner(_ text: String, color: Color) -> some View {
        Text(text)
            .font(DFFont.caption)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(color.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func chip(_ text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11))
        }
        .foregroundStyle(DFColor.inkMuted)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(DFColor.surfaceAlt, in: Capsule())
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

    // MARK: - 数据与动作

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            switch tab {
            case .messages:
                messages = try await container.proactive.list(
                    includeDeleted: includeDeleted,
                    limit: 200
                )
            case .runs:
                runs = try await container.autonomy.runs(limit: 100)
            }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func showExplanation(_ item: ProactiveMessage) async {
        do {
            let value = try await container.proactive.explain(id: item.id)
            explanationRoute = ExplanationRoute(value: value)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func toggleFavorite(_ item: ProactiveMessage) async {
        do {
            _ = try await container.proactive.setFavorite(id: item.id, favorite: !item.isFavorite)
            message = item.isFavorite ? "已取消收藏" : "已收藏"
            await reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func markNotInterested(_ item: ProactiveMessage) async {
        do {
            _ = try await container.proactive.setFeedback(id: item.id, feedback: .notInterested)
            message = "已记录「不感兴趣」，同类主动消息会被抑制"
            await reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func remove(_ item: ProactiveMessage) async {
        do {
            try await container.proactive.delete(id: item.id)
            message = "已删除（保留触发原因，可追溯）"
            await reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: - 文案

    private static func timeText(_ millis: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000))
    }

    private func statusTitle(_ status: ProactiveMessageStatus) -> String {
        switch status {
        case .planned: return "待发"
        case .sent: return "已发"
        case .suppressed: return "被拦下"
        case .failed: return "失败"
        case .deleted: return "已删除"
        }
    }

    private func statusColor(_ status: ProactiveMessageStatus) -> Color {
        switch status {
        case .planned: return DFColor.primaryDeep
        case .sent: return DFColor.success
        case .suppressed: return DFColor.warning
        case .failed: return DFColor.danger
        case .deleted: return DFColor.inkMuted
        }
    }
}

/// 触发原因详情：只读展示，解释"为什么会有这条主动消息"。
@MainActor
private struct ProactiveExplanationView: View {
    @Environment(\.dismiss) private var dismiss

    let explanation: ProactiveMessageExplanation

    var body: some View {
        List {
            Section("触发") {
                LabeledContent("类型", value: explanation.triggerKind ?? "未记录")
                LabeledContent("来源", value: explanation.triggerRef ?? "未记录")
            }
            Section("理由") {
                Text(explanation.intentReason ?? "没有记录理由")
                    .font(.system(size: 13))
                    .foregroundStyle(DFColor.ink)
            }
            if let memoryID = explanation.relatedMemoryID {
                Section("关联记忆") {
                    Text(memoryID)
                        .font(.system(size: 11))
                        .foregroundStyle(DFColor.inkMuted)
                    Text("可在「记忆」页搜索该 ID 对应的内容。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let evidence = explanation.evidenceJSON, !evidence.isEmpty {
                Section("证据") {
                    Text(evidence)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DFColor.inkMuted)
                }
            }
        }
        .navigationTitle("触发原因")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
    }
}

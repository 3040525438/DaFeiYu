import SwiftUI
import DFCore

/// 记忆页：长期记忆的真实管理界面。
///
/// 接入的是 `memories` 表与 `memory_fts`，而不是统计占位：
/// - 浏览：按归属筛选、搜索、包含归档；
/// - 详情：全文、来源（哪条消息 / 哪篇日记）、版本历史；
/// - 修正：改标题与正文（写版本快照 + 重建索引）；
/// - 归档 / 删除 / 恢复；
/// - 待确认提案：确认后才真正写入，驳回不影响原始数据。
@MainActor
struct MemoryView: View {
    @EnvironmentObject private var container: AppContainer

    @State private var stats = CompanionStats()
    @State private var memories: [MemoryRecord] = []
    @State private var proposals: [MemoryProposalSummary] = []
    @State private var scopeFilter: MemoryScopeFilter = .all
    @State private var searchText = ""
    @State private var includeArchived = false
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var selected: MemoryRecord?
    @State private var actionMessage: String?

    private var memoryCount: Int { memories.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    archiveCover
                    statTiles
                    searchField
                    filterRow

                    if let actionMessage {
                        banner(actionMessage, color: DFColor.primaryDeep)
                    }
                    if let loadError {
                        banner("记忆读取失败：\(loadError)", color: DFColor.danger)
                    }

                    if !proposals.isEmpty {
                        proposalsSection
                    }

                    content

                    if !isLoading && memories.isEmpty && loadError == nil {
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("刷新记忆")
                }
            }
        }
        .task { await reload() }
        .sheet(item: $selected) { record in
            NavigationStack {
                MemoryDetailView(record: record) { message in
                    actionMessage = message
                    Task { await reload() }
                }
                .environmentObject(container)
            }
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .tint(DFColor.primary)
                .padding(.top, 24)
        } else if memories.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 10) {
                ForEach(memories) { record in
                    Button {
                        selected = record
                    } label: {
                        memoryCard(record)
                    }
                    .buttonStyle(.plain)
                }
                Text("共 \(memoryCount) 条，按重要度排序；已删除的记忆不会再被自动重新生成。")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.inkMuted)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - 搜索与筛选

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(DFColor.inkMuted)
            TextField("搜索记忆内容、标签", text: $searchText)
                .font(.system(size: 14))
                .submitLabel(.search)
                .onSubmit { Task { await reload() } }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    Task { await reload() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DFColor.inkMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(DFColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(DFColor.hairline, lineWidth: 1)
        )
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(MemoryScopeFilter.allCases, id: \.self) { item in
                    Button {
                        scopeFilter = item
                        Task { await reload() }
                    } label: {
                        Text(item.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(scopeFilter == item ? DFColor.surface : DFColor.inkMuted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(scopeFilter == item ? DFColor.primaryDeep : DFColor.surfaceAlt)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    includeArchived.toggle()
                    Task { await reload() }
                } label: {
                    Text(includeArchived ? "含已归档" : "仅活跃")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(includeArchived ? DFColor.surface : DFColor.inkMuted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(includeArchived ? DFColor.lilac : DFColor.surfaceAlt)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 提案

    private var proposalsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 12))
                    .foregroundStyle(DFColor.warning)
                Text("待你确认的 \(proposals.count) 条记忆")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DFColor.ink)
                Spacer()
            }

            ForEach(proposals) { proposal in
                VStack(alignment: .leading, spacing: 6) {
                    Text(proposal.title.isEmpty ? proposal.content : proposal.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DFColor.ink)
                    if !proposal.content.isEmpty {
                        Text(proposal.content)
                            .font(DFFont.caption)
                            .foregroundStyle(DFColor.inkMuted)
                            .lineLimit(3)
                    }
                    if !proposal.evidenceQuote.isEmpty {
                        Text("依据：\(proposal.evidenceQuote)")
                            .font(.system(size: 10))
                            .foregroundStyle(DFColor.inkMuted.opacity(0.8))
                            .lineLimit(2)
                    }
                    HStack(spacing: 8) {
                        Button {
                            Task { await approve(proposal) }
                        } label: {
                            Text("确认写入")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(DFColor.surface)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(DFColor.primaryDeep)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Button {
                            Task { await reject(proposal) }
                        } label: {
                            Text("驳回")
                                .font(.system(size: 12))
                                .foregroundStyle(DFColor.inkMuted)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(DFColor.surfaceAlt)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DFColor.surface)
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous)
                        .stroke(DFColor.warning.opacity(0.35), lineWidth: 1)
                )
            }
        }
        .padding(12)
        .background(DFColor.warning.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous))
    }

    // MARK: - 数据

    private func reload() async {
        do {
            stats = await CompanionStats.load(container: container)
            proposals = await container.pendingMemoryProposals()
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                memories = try await container.memories.memories(
                    scope: scopeFilter.scope,
                    layer: nil,
                    includeArchived: includeArchived,
                    limit: 200,
                    offset: 0
                )
            } else {
                let hits = try await container.memories.search(
                    query: searchText,
                    scope: scopeFilter.scope,
                    limit: 100
                )
                memories = hits.filter { includeArchived || !$0.isArchived }
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func approve(_ proposal: MemoryProposalSummary) async {
        do {
            try await container.approveMemoryProposal(id: proposal.id)
            actionMessage = "已写入一条记忆"
        } catch {
            actionMessage = "确认失败：\(error.localizedDescription)"
        }
        await reload()
    }

    private func reject(_ proposal: MemoryProposalSummary) async {
        do {
            try await container.rejectMemoryProposal(id: proposal.id)
            actionMessage = "已驳回，原始聊天不受影响"
        } catch {
            actionMessage = "驳回失败：\(error.localizedDescription)"
        }
        await reload()
    }

    // MARK: - 卡片

    private func memoryCard(_ record: MemoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(record.title.isEmpty ? "未命名记忆" : record.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DFColor.ink)
                    .lineLimit(1)
                Spacer()
                if record.isArchived {
                    tag("已归档", color: DFColor.inkMuted)
                }
                tag(scopeTitle(record.scope), color: DFColor.primaryDeep)
            }

            Text(record.content)
                .font(DFFont.caption)
                .foregroundStyle(DFColor.inkMuted)
                .lineLimit(4)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 5) {
                tag(layerTitle(record.layer), color: DFColor.primaryDeep)
                if !record.category.isEmpty {
                    tag(categoryTitle(record.category), color: DFColor.inkMuted)
                }
                Spacer()
                Text("重要度 \(scoreText(record.importanceScore ?? record.salience))")
                    .font(.system(size: 10))
                    .foregroundStyle(DFColor.inkMuted)
            }

            Text("更新于 \(Self.dateText(record.updatedAt)) · 可信度 \(scoreText(record.confidence))")
                .font(.system(size: 10))
                .foregroundStyle(DFColor.inkMuted.opacity(0.85))
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

    // MARK: - 统计与封面

    private var statTiles: some View {
        HStack(spacing: 8) {
            statTile(value: "\(stats.messageCount)", label: "对话消息")
            statTile(value: "\(stats.dayCount)", label: "陪伴天数")
            statTile(value: "\(memories.count)", label: "记忆条目")
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

                Text("\(memories.count)")
                    .font(DFFont.number)
                    .foregroundStyle(DFColor.ink)

                Text("条长期记忆 · 从 \(CompanionStats.dateText(stats.startedAt)) 开始 · 一起走过 \(stats.dayCount) 天")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.inkMuted)
            }
            .padding(16)
        }
        .frame(height: 126)
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.panel, style: .continuous)
                .stroke(DFColor.hairline, lineWidth: 1)
        )
    }

    private var emptyCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .font(.system(size: 22))
                .foregroundStyle(DFColor.lilac)
            Text(searchText.isEmpty ? "还没有长期记忆" : "没有匹配的记忆")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DFColor.ink)
            Text("聊天里出现值得长期保留的信息时，大肥鱼会自动整理；重要内容会先在这里等你确认。")
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

    // MARK: - 文案

    static func dateText(_ millis: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000))
    }

    static func dateTimeText(_ millis: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000))
    }

    private func scoreText(_ value: Double) -> String {
        String(format: "%.2f", min(max(value, 0), 1))
    }

    private func scopeTitle(_ scope: MemoryScope) -> String {
        switch scope {
        case .user: return "用户"
        case .shared: return "共同"
        case .selfScope: return "自我"
        }
    }

    private func layerTitle(_ layer: String) -> String {
        switch layer {
        case "episodic": return "情景"
        case "semantic": return "语义"
        case "procedural": return "习惯"
        case "reflective": return "反思"
        default: return layer.isEmpty ? "记忆" : layer
        }
    }

    private func categoryTitle(_ category: String) -> String {
        switch category {
        case "preference": return "偏好"
        case "fact": return "事实"
        case "event": return "事件"
        case "relationship": return "关系"
        case "reflection": return "反思"
        case "plan": return "计划"
        default: return category
        }
    }
}

/// 归属筛选
enum MemoryScopeFilter: CaseIterable, Hashable {
    case all
    case user
    case shared
    case selfScope

    var title: String {
        switch self {
        case .all: return "全部"
        case .user: return "用户"
        case .shared: return "共同"
        case .selfScope: return "自我"
        }
    }

    var scope: MemoryScope? {
        switch self {
        case .all: return nil
        case .user: return .user
        case .shared: return .shared
        case .selfScope: return .selfScope
        }
    }
}

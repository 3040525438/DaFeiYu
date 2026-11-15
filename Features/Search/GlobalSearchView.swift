import SwiftUI
import DFCore

/// D25：全局搜索界面。
///
/// 结果按域分组展示；消息命中交给聊天页跳转定位，记忆 / 日记 / 附件命中打开只读详情。
@MainActor
struct GlobalSearchView: View {
    @StateObject private var viewModel: GlobalSearchViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    /// 打开会话并定位消息（由聊天页实现）
    private let onOpenMessage: (String, String) -> Void

    @State private var detail: GlobalSearchDetail?

    init(container: AppContainer, onOpenMessage: @escaping (String, String) -> Void) {
        _viewModel = StateObject(wrappedValue: GlobalSearchViewModel(container: container))
        self.onOpenMessage = onOpenMessage
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                domainBar
                Divider()
                content
            }
            .background(DFColor.canvas)
            .navigationTitle("全局搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $detail) { item in
                GlobalSearchDetailSheet(detail: item)
            }
        }
        .task(id: viewModel.query) {
            // 输入防抖：停止输入 300ms 后再检索，避免每个字符都打一次库
            if viewModel.trimmedQuery.isEmpty {
                await viewModel.search()
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await viewModel.search()
        }
        .onAppear { isFocused = true }
    }

    // MARK: - 搜索框

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DFColor.inkMuted)
            TextField("搜索聊天、记忆、日记、附件", text: $viewModel.query)
                .focused($isFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit { Task { await viewModel.search() } }
            if !viewModel.query.isEmpty {
                Button {
                    viewModel.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DFColor.inkMuted)
                }
                .accessibilityLabel("清空搜索")
            }
            if viewModel.isSearching {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(DFColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var domainBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchDomain.allCases, id: \.self) { domain in
                    let enabled = viewModel.isEnabled(domain)
                    Button {
                        viewModel.toggle(domain)
                    } label: {
                        Text(domain.displayName)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(enabled ? DFColor.primary : DFColor.surfaceAlt)
                            .foregroundStyle(enabled ? Color.white : DFColor.inkMuted)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - 结果

    @ViewBuilder
    private var content: some View {
        if let error = viewModel.errorText {
            emptyState(icon: "exclamationmark.triangle", title: "搜索失败", message: error)
        } else if viewModel.trimmedQuery.isEmpty {
            emptyState(icon: "magnifyingglass", title: "输入关键词开始搜索", message: "会同时检索聊天、记忆、日记与附件文字，归档会话也可被搜到。")
        } else if viewModel.hasSearched && viewModel.hits.isEmpty && !viewModel.isSearching {
            emptyState(icon: "tray", title: "没有找到结果", message: "换个关键词，或放宽搜索范围试试。")
        } else {
            List {
                ForEach(viewModel.grouped, id: \.domain) { group in
                    Section(group.domain.displayName) {
                        ForEach(group.hits) { hit in
                            row(hit)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder
    private func row(_ hit: UnifiedSearchHit) -> some View {
        Button {
            open(hit)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(hit.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DFColor.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let createdAt = hit.createdAt {
                        Text(Self.timeText(createdAt))
                            .font(.caption2)
                            .foregroundStyle(DFColor.inkMuted)
                    }
                }
                Text(hit.snippet)
                    .font(.system(size: 12))
                    .foregroundStyle(DFColor.inkMuted)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Text(sourceText(hit))
                    .font(.caption2)
                    .foregroundStyle(DFColor.primary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sourceText(_ hit: UnifiedSearchHit) -> String {
        switch hit.domain {
        case .message:
            return hit.conversationID == nil ? "聊天消息" : "聊天 · 点击定位到消息"
        case .memory:
            return "记忆 · 点击查看全文"
        case .diary:
            return "日记\(hit.diaryDate.map { " · \($0)" } ?? "") · 点击查看"
        case .attachment:
            return hit.messageID == nil ? "附件文字 · 点击查看片段" : "附件文字 · 点击定位到消息"
        }
    }

    private func open(_ hit: UnifiedSearchHit) {
        switch hit.domain {
        case .message:
            guard let conversationID = hit.conversationID else {
                Task { detail = await viewModel.detail(for: hit) }
                return
            }
            onOpenMessage(conversationID, hit.messageID ?? hit.targetID)
            dismiss()
        case .attachment:
            if let conversationID = hit.conversationID, let messageID = hit.messageID {
                onOpenMessage(conversationID, messageID)
                dismiss()
            } else {
                Task { detail = await viewModel.detail(for: hit) }
            }
        case .memory, .diary:
            Task { detail = await viewModel.detail(for: hit) }
        }
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(DFColor.inkMuted.opacity(0.7))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DFColor.ink)
            Text(message)
                .font(.caption)
                .foregroundStyle(DFColor.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func timeText(_ millis: Int64) -> String {
        Self.formatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000))
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

/// 只读详情：展示完整正文与来源，不做编辑。
private struct GlobalSearchDetailSheet: View {
    let detail: GlobalSearchDetail
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(detail.source)
                        .font(.caption)
                        .foregroundStyle(DFColor.primary)
                    Text(detail.title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(DFColor.ink)
                    Text(detail.body)
                        .font(.system(size: 14))
                        .foregroundStyle(DFColor.ink)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .background(DFColor.canvas)
            .navigationTitle("详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

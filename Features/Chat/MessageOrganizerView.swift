import SwiftUI
import DFCore

/// D26：消息整理界面（收藏 / 重要 / 标签 / 批量）。
///
/// 整理不会生成记忆，也不会改动人格；这里只负责把标记落到消息上。
@MainActor
struct MessageOrganizerView: View {
    @StateObject private var viewModel: MessageOrganizerViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showTagInput = false
    @State private var tagDraft = ""
    @State private var tagAction: TagAction = .add

    private enum TagAction: Equatable {
        case add
        case remove(String)
    }

    init(container: AppContainer) {
        _viewModel = StateObject(wrappedValue: MessageOrganizerViewModel(container: container))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                Divider()
                list
                if viewModel.selectionCount > 0 {
                    actionBar
                }
            }
            .background(DFColor.canvas)
            .navigationTitle("消息整理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(viewModel.selectionCount == viewModel.items.count && !viewModel.items.isEmpty ? "取消全选" : "全选") {
                        if viewModel.selectionCount == viewModel.items.count && !viewModel.items.isEmpty {
                            viewModel.clearSelection()
                        } else {
                            viewModel.selectAll()
                        }
                    }
                    .disabled(viewModel.items.isEmpty)
                }
            }
            .alert(tagAction == .add ? "添加标签" : "移除标签", isPresented: $showTagInput) {
                TextField("标签名", text: $tagDraft)
                Button("取消", role: .cancel) {}
                Button("确定") {
                    let text = tagDraft
                    let action = tagAction
                    Task {
                        switch action {
                        case .add:
                            await viewModel.addTag(text)
                        case .remove:
                            await viewModel.removeTag(text)
                        }
                    }
                }
            }
        }
        .task { await viewModel.reload() }
        .onChange(of: viewModel.filter) { _, _ in
            Task { await viewModel.reload() }
        }
    }

    // MARK: - 过滤

    private var filterBar: some View {
        VStack(spacing: 8) {
            Picker("范围", selection: $viewModel.filter) {
                Text("收藏").tag(MessageFilter.favorite)
                Text("重要").tag(MessageFilter.important)
                Text("全部").tag(MessageFilter.all)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.tagSummary) { item in
                        let active = viewModel.filter == .tagged(item.tag)
                        Button {
                            viewModel.filter = active ? .favorite : .tagged(item.tag)
                        } label: {
                            Text("#\(item.tag) \(item.count)")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(active ? DFColor.primary : DFColor.surfaceAlt)
                                .foregroundStyle(active ? Color.white : DFColor.inkMuted)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    if viewModel.tagSummary.isEmpty {
                        Text("还没有标签：选中消息后可批量添加")
                            .font(.caption2)
                            .foregroundStyle(DFColor.inkMuted)
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.bottom, 8)

            if let message = viewModel.lastMessage {
                banner(message)
            }
            if let error = viewModel.errorText {
                banner("⚠︎ \(error)", isError: true)
            }
        }
        .background(DFColor.canvas)
        .onChange(of: viewModel.lastMessage) { _, value in
            guard value != nil else { return }
            Task {
                try? await Task.sleep(nanoseconds: 2_400_000_000)
                viewModel.clearLastMessage()
            }
        }
    }

    private func banner(_ text: String, isError: Bool = false) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(isError ? Color.red : DFColor.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
    }

    // MARK: - 列表

    @ViewBuilder
    private var list: some View {
        if viewModel.isLoading && viewModel.items.isEmpty {
            ProgressView("加载中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "bookmark")
                    .font(.system(size: 24))
                    .foregroundStyle(DFColor.inkMuted.opacity(0.7))
                Text("这里还没有消息")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DFColor.ink)
                Text(emptyHint)
                    .font(.caption)
                    .foregroundStyle(DFColor.inkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(viewModel.items) { item in
                row(item)
                    .listRowBackground(DFColor.surface)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var emptyHint: String {
        switch viewModel.filter {
        case .favorite: return "在聊天里长按消息即可收藏。"
        case .important: return "在聊天里长按消息即可标记重要。"
        case .all: return "还没有任何消息。"
        case .tagged(let tag): return "还没有消息带标签「\(tag)」。"
        }
    }

    private func row(_ item: MessageOrganizerViewModel.Item) -> some View {
        let selected = viewModel.selection.contains(item.id)
        return Button {
            viewModel.toggleSelection(item.id)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? DFColor.primary : DFColor.inkMuted)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.message.role == .user ? "我" : "大肥鱼")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DFColor.primary)
                        Text(Self.timeText(item.message.createdAt))
                            .font(.caption2)
                            .foregroundStyle(DFColor.inkMuted)
                        if item.message.isFavorite {
                            Image(systemName: "bookmark.fill")
                                .font(.caption2)
                                .foregroundStyle(DFColor.accentPink)
                        }
                    }
                    Text(item.message.text.isEmpty ? "（无文字内容）" : item.message.text)
                        .font(.system(size: 13))
                        .foregroundStyle(DFColor.ink)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    if !item.tags.isEmpty {
                        Text(item.tags.map { "#\($0)" }.joined(separator: "  "))
                            .font(.caption2)
                            .foregroundStyle(DFColor.inkMuted)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 批量操作

    private var actionBar: some View {
        VStack(spacing: 6) {
            Text("已选 \(viewModel.selectionCount) 条")
                .font(.caption2)
                .foregroundStyle(DFColor.inkMuted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    actionButton("收藏", icon: "bookmark") {
                        Task { await viewModel.setFavorite(true) }
                    }
                    actionButton("取消收藏", icon: "bookmark.slash") {
                        Task { await viewModel.setFavorite(false) }
                    }
                    actionButton("标为重要", icon: "exclamationmark.circle") {
                        Task { await viewModel.setImportant(true) }
                    }
                    actionButton("取消重要", icon: "exclamationmark.circle.fill") {
                        Task { await viewModel.setImportant(false) }
                    }
                    actionButton("添加标签", icon: "tag") {
                        tagDraft = ""
                        tagAction = .add
                        showTagInput = true
                    }
                    actionButton("移除标签", icon: "tag.slash") {
                        tagDraft = commonTag ?? ""
                        tagAction = .remove(tagDraft)
                        showTagInput = true
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
        .background(DFColor.surface)
        .overlay(alignment: .top) { Divider() }
    }

    /// 选中消息里出现过的第一个标签，作为"移除标签"的默认值
    private var commonTag: String? {
        viewModel.items
            .filter { viewModel.selection.contains($0.id) }
            .flatMap(\.tags)
            .first
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(DFColor.primarySoft)
                .foregroundStyle(DFColor.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
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

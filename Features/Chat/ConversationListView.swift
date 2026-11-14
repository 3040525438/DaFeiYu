import SwiftUI
import DFCore

/// W3：多会话列表。
///
/// 只做展示与转发，业务判断（生成中禁止切换、删除保护、删除后回到主会话）都在 `ChatViewModel`。
@MainActor
struct ConversationListView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var newTitle = ""
    @State private var showCreate = false
    @State private var renaming: ConversationSummary?
    @State private var renameText = ""
    @State private var pendingDelete: ConversationSummary?
    @State private var showArchived = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if viewModel.conversations.isEmpty {
                        Text("还没有会话").foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.conversations) { item in
                        row(item)
                    }
                }

                Section {
                    Toggle("显示归档会话", isOn: $showArchived)
                    if showArchived {
                        if viewModel.archivedConversations.isEmpty {
                            Text("暂无归档会话").foregroundStyle(.secondary)
                        }
                        ForEach(viewModel.archivedConversations) { item in
                            row(item)
                        }
                    }
                } footer: {
                    Text("归档会话不占用主列表，但仍可进入、可被全局搜索检索。")
                }

                if viewModel.unreadTotal > 0 {
                    Section {
                        Button("全部标为已读（\(viewModel.unreadTotal)）") {
                            Task { await viewModel.markAllConversationsRead() }
                        }
                    }
                }
            }
            .navigationTitle("会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newTitle = ""
                        showCreate = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("新建会话")
                }
            }
            .alert("新建会话", isPresented: $showCreate) {
                TextField("会话标题", text: $newTitle)
                Button("取消", role: .cancel) {}
                Button("创建") {
                    let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { return }
                    Task {
                        await viewModel.createConversation(title: title)
                        dismiss()
                    }
                }
            }
            .alert("重命名会话", isPresented: renameBinding) {
                TextField("会话标题", text: $renameText)
                Button("取消", role: .cancel) { renaming = nil }
                Button("保存") {
                    let target = renaming
                    let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    renaming = nil
                    guard let target, !title.isEmpty else { return }
                    Task { await viewModel.renameConversation(id: target.id, title: title) }
                }
            }
            .alert("删除会话", isPresented: deleteBinding) {
                Button("取消", role: .cancel) { pendingDelete = nil }
                Button("删除", role: .destructive) {
                    guard let target = pendingDelete else { return }
                    pendingDelete = nil
                    Task { await viewModel.deleteConversations(ids: [target.id]) }
                }
            } message: {
                Text("将删除该会话的全部消息；记忆、日记与人格都会保留。此操作不可撤销。")
            }
        }
        .task {
            await viewModel.refreshConversationList()
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    @ViewBuilder
    private func row(_ item: ConversationSummary) -> some View {
        Button {
            Task {
                await viewModel.switchConversation(to: item.id)
                dismiss()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.isPinned ? "pin.fill" : "bubble.left")
                    .foregroundStyle(item.isPinned ? DFColor.primary : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text(subtitle(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if item.hasUnread {
                    Text("\(item.unreadCount)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.red))
                        .foregroundStyle(.white)
                }
                if item.id == viewModel.activeConversationID {
                    Image(systemName: "checkmark")
                        .foregroundStyle(DFColor.primary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if item.kind != "main" {
                Button(role: .destructive) {
                    pendingDelete = item
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
            Button {
                renameText = item.title
                renaming = item
            } label: {
                Label("改名", systemImage: "pencil")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                Task { await viewModel.togglePin(item) }
            } label: {
                Label(item.isPinned ? "取消置顶" : "置顶", systemImage: item.isPinned ? "pin.slash" : "pin")
            }
            .tint(.blue)

            if item.kind != "main" {
                Button {
                    Task { await viewModel.toggleArchive(item) }
                } label: {
                    Label(item.isArchived ? "取消归档" : "归档", systemImage: "archivebox")
                }
                .tint(.gray)
            }
        }
        .contextMenu {
            Button {
                Task { await viewModel.togglePin(item) }
            } label: {
                Label(item.isPinned ? "取消置顶" : "置顶", systemImage: item.isPinned ? "pin.slash" : "pin")
            }
            Button {
                renameText = item.title
                renaming = item
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            if item.kind != "main" {
                Button {
                    Task { await viewModel.toggleArchive(item) }
                } label: {
                    Label(item.isArchived ? "取消归档" : "归档", systemImage: "archivebox")
                }
                Button(role: .destructive) {
                    pendingDelete = item
                } label: {
                    Label("删除会话", systemImage: "trash")
                }
            }
        }
    }

    private func subtitle(_ item: ConversationSummary) -> String {
        var parts: [String] = []
        if item.kind == "main" { parts.append("主线") }
        if item.isArchived { parts.append("已归档") }
        parts.append("\(item.messageCount) 条消息")
        if let last = item.lastMessageAt {
            parts.append(Self.formatter.string(from: Date(timeIntervalSince1970: Double(last) / 1000)))
        }
        return parts.joined(separator: " · ")
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

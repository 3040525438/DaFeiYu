import SwiftUI
import UIKit
import DFCore

@MainActor
struct ChatView: View {
    @StateObject private var viewModel: ChatViewModel
    @FocusState private var isInputFocused: Bool
    @State private var isSearching = false
    @State private var showThemeSheet = false
    @State private var showClearConfirm = false
    @State private var showKeywordDelete = false
    @State private var deleteKeyword = ""
    @State private var showConversations = false
    private let onOpenSettings: () -> Void

    @MainActor
    init(container: AppContainer, onOpenSettings: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: ChatViewModel(container: container))
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isSearching {
                    searchBar
                }
                if !viewModel.searchHits.isEmpty {
                    searchResults
                }
                messageList
                composer
            }
            .background(alignment: .top) { chatBackground }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(backgroundBaseColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) { headerTitle }
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 14) {
                        Button {
                            showConversations = true
                        } label: {
                            Image(systemName: "list.bullet")
                                .overlay(alignment: .topTrailing) {
                                    if viewModel.unreadTotal > 0 {
                                        Text("\(min(viewModel.unreadTotal, 99))")
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 3)
                                            .background(Capsule().fill(Color.red))
                                            .foregroundStyle(.white)
                                            .offset(x: 8, y: -8)
                                    }
                                }
                        }
                        .accessibilityLabel("会话列表")
                        Button {
                            isSearching.toggle()
                            if !isSearching { viewModel.clearSearch() }
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .accessibilityLabel("搜索会话")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showThemeSheet = true
                        } label: {
                            Label("外观", systemImage: "paintpalette")
                        }
                        Divider()
                        Button {
                            deleteToday()
                        } label: {
                            Label("删除今天的消息", systemImage: "calendar.badge.minus")
                        }
                        Button {
                            showKeywordDelete = true
                        } label: {
                            Label("按关键词删除…", systemImage: "text.badge.minus")
                        }
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Label("清空会话", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("更多操作")
                }
                // 键盘上方的收起按钮：滑动手势不一定生效，需要一个明确出口
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起") {
                        isInputFocused = false
                    }
                }
            }
        }
        .tint(DFColor.primary)
        .task {
            await viewModel.onAppear()
        }
        .onDisappear {
            viewModel.onDisappear()
        }
        .alert("提示", isPresented: errorBinding) {
            Button("知道了", role: .cancel) {
                viewModel.errorText = nil
            }
        } message: {
            Text(viewModel.errorText ?? "")
        }
        .alert("清空会话", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                Task { await viewModel.delete(.conversation(viewModel.conversationIDForDeletion)) }
            }
        } message: {
            Text("将删除本会话的全部消息（记忆与人格不受影响）。")
        }
        .alert("按关键词删除", isPresented: $showKeywordDelete) {
            TextField("关键词", text: $deleteKeyword)
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                let keyword = deleteKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !keyword.isEmpty else { return }
                deleteKeyword = ""
                Task { await viewModel.delete(.keyword(keyword)) }
            }
        } message: {
            Text("只删除正文包含该关键词的消息。")
        }
        .sheet(isPresented: $showThemeSheet) {
            ThemeSettingsSheet(
                theme: viewModel.theme,
                onSave: { updated in
                    Task { await viewModel.saveTheme(updated) }
                },
                onReset: {
                    Task { await viewModel.resetTheme() }
                }
            )
        }
        .sheet(isPresented: $showConversations) {
            ConversationListView(viewModel: viewModel)
        }
        .sheet(item: $viewModel.editingMessage) { message in
            EditMessageSheet(
                message: message,
                draft: $viewModel.editDraft,
                onCancel: { viewModel.cancelEdit() },
                onSave: { Task { await viewModel.commitEdit() } }
            )
        }
    }

    private func deleteToday() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? Date()
        Task {
            await viewModel.delete(
                .dateRange(
                    fromMillis: Clock.millis(from: start),
                    toMillis: Clock.millis(from: end)
                )
            )
        }
    }

    /// 导航栏底色随主题变化（暗色主题下不刺眼）
    private var backgroundBaseColor: Color {
        viewModel.theme.background == "dark"
            ? Color(red: 0.09, green: 0.09, blue: 0.11)
            : DFColor.canvas
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorText != nil },
            set: { newValue in
                if !newValue { viewModel.errorText = nil }
            }
        )
    }

    // MARK: - 头部

    private var headerTitle: some View {
        HStack(spacing: 8) {
            DFCharacterMark(size: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text("大肥鱼")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DFColor.ink)
                    Circle()
                        .fill(DFColor.success)
                        .frame(width: 5, height: 5)
                }
                Text(viewModel.isStreaming ? "正在输入…" : "本地存储 · 只有你和她")
                    .font(.system(size: 9))
                    .foregroundStyle(DFColor.inkMuted)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - 消息流

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if !viewModel.hasModel {
                        emptyBanner
                    }
                    ForEach(viewModel.messages) { message in
                        MessageRow(
                            message: message,
                            isStreaming: isStreaming(message),
                            isPendingRecovery: viewModel.isPendingRecovery(message),
                            theme: viewModel.theme,
                            onRetry: { viewModel.retry(message) },
                            onDelete: { viewModel.delete(.ids([message.id])) },
                            onEdit: { viewModel.beginEdit(message) },
                            onRevoke: { Task { await viewModel.revoke(message) } },
                            onToggleFavorite: { Task { await viewModel.toggleFavorite(message) } }
                        )
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 18)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.messages.count) { _, _ in
                guard let last = viewModel.messages.last else { return }
                withAnimation(DFMotion.messageIn) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: viewModel.scrollTargetID) { _, target in
                guard let target else { return }
                withAnimation(DFMotion.messageIn) {
                    proxy.scrollTo(target, anchor: .center)
                }
                viewModel.scrollTargetID = nil
            }
        }
    }

    // MARK: - 搜索

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(DFColor.inkMuted)
            TextField("搜索本会话的消息", text: $viewModel.searchQuery)
                .font(DFFont.caption)
                .submitLabel(.search)
                .onSubmit { Task { await viewModel.runSearch() } }
            Button("搜索") {
                Task { await viewModel.runSearch() }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(DFColor.primary)

            Button {
                isSearching = false
                viewModel.clearSearch()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(DFColor.inkMuted)
            }
            .accessibilityLabel("关闭搜索")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(DFColor.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DFColor.hairline).frame(height: 1)
        }
    }

    private var searchResults: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.searchHits) { hit in
                    Button {
                        Task { await viewModel.revealSearchHit(hit) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "text.magnifyingglass")
                                .font(.system(size: 11))
                                .foregroundStyle(DFColor.inkMuted)
                            Text(previewText(for: hit))
                                .font(DFFont.caption)
                                .foregroundStyle(DFColor.ink)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                    }
                    Divider().overlay(DFColor.hairline)
                }
            }
        }
        .frame(maxHeight: 180)
        .background(DFColor.surface)
    }

    private func previewText(for hit: ChatSearchHit) -> String {
        viewModel.messages.first { $0.id == hit.messageID }?.text ?? hit.messageID
    }

    /// 页面底色：随主题变化（暗色不叠加柔光/暗纹，避免脏色）
    private var chatBackground: some View {
        ZStack(alignment: .top) {
            backgroundBaseColor
            switch viewModel.theme.background {
            case "dark", "plain":
                EmptyView()
            default:
                DFSoftGlow()
                    .frame(height: 260)
                    .clipped()
                DFScaleBackdrop(opacity: 0.16)
                    .frame(height: 190)
            }
        }
        .ignoresSafeArea()
    }

    private func isStreaming(_ message: Message) -> Bool {
        viewModel.isStreaming
            && message.role == .assistant
            && message.id == viewModel.messages.last?.id
    }

    private var emptyBanner: some View {
        VStack(spacing: 8) {
            Text("还没有配置模型")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DFColor.ink)
            Text("先去设置里添加一个 OpenAI 兼容的接口，才能开始聊天。")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.inkMuted)
                .multilineTextAlignment(.center)
            Button("去设置") {
                onOpenSettings()
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(DFColor.primary, in: Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(DFColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous)
                .stroke(DFColor.hairline, lineWidth: 1)
        )
    }

    // MARK: - 输入栏

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("说点什么…", text: $viewModel.draft, axis: .vertical)
                .lineLimit(1...4)
                .font(DFFont.body)
                .foregroundStyle(DFColor.ink)
                .focused($isInputFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(DFColor.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(DFColor.hairline, lineWidth: 1)
                )

            Button {
                if viewModel.isStreaming {
                    viewModel.stop()
                } else {
                    viewModel.send()
                }
            } label: {
                Image(systemName: viewModel.isStreaming ? "stop.fill" : "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(DFColor.bubbleMe, in: Circle())
                    .opacity(canTrigger ? 1 : 0.4)
            }
            .disabled(!canTrigger)
            .accessibilityLabel(viewModel.isStreaming ? "停止生成" : "发送")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(DFColor.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DFColor.hairline)
                .frame(height: 1)
        }
    }

    /// 生成中按钮变为"停止"，其余情况按草稿是否为空决定可用性
    private var canTrigger: Bool {
        if viewModel.isStreaming { return true }
        return !viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

@MainActor
struct MessageRow: View {
    let message: Message
    var isStreaming: Bool = false
    /// 该轮次还没收尾（库里组仍 open）：显示"待恢复"，不得显示为成功/失败/取消
    var isPendingRecovery: Bool = false
    var theme: ChatTheme = .default
    let onRetry: () -> Void
    let onDelete: () -> Void
    var onEdit: () -> Void = {}
    var onRevoke: () -> Void = {}
    var onToggleFavorite: () -> Void = {}

    private var isUser: Bool {
        message.role == .user
    }

    private var isRevoked: Bool { message.revokedAt != nil }

    /// 只有失败的 assistant 才提供重试入口（重试会新建组，不是删了重发）
    private var canRetry: Bool {
        message.role == .assistant && message.status == .failed
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 36) }
            if !isUser { avatar }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                MessageBubble(
                    text: displayText,
                    kind: isUser ? .me : .other,
                    isFailed: message.status == .failed || isRevoked,
                    isStreaming: isStreaming,
                    theme: theme
                )
                .contextMenu {
                    if !isRevoked {
                        Button {
                            UIPasteboard.general.string = message.text
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                        }
                        Button(action: onEdit) {
                            Label("编辑", systemImage: "pencil")
                        }
                        Button(action: onToggleFavorite) {
                            Label(
                                message.isFavorite ? "取消收藏" : "收藏",
                                systemImage: message.isFavorite ? "star.slash" : "star"
                            )
                        }
                    }
                    if canRetry {
                        Button(action: onRetry) {
                            Label("重试", systemImage: "arrow.clockwise")
                        }
                    }
                    if !isRevoked {
                        Button(action: onRevoke) {
                            Label("撤回", systemImage: "arrow.uturn.backward")
                        }
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("删除", systemImage: "trash")
                    }
                }

                if isPendingRecovery {
                    pendingRow
                } else if canRetry {
                    FailedRetryRow(onRetry: onRetry)
                } else {
                    footer
                }
            }

            if isUser { avatar }
            if isUser { Spacer(minLength: 0) }
            if !isUser { Spacer(minLength: 36) }
        }
    }

    private var displayText: String {
        if isRevoked { return isUser ? "你撤回了一条消息" : "这条消息已撤回" }
        if !message.text.isEmpty { return message.text }
        if isPendingRecovery { return "上一轮尚未完成" }
        if message.status == .sending { return "…" }
        if message.status == .canceled { return "已停止" }
        return message.text
    }

    /// 待恢复：正式的提示行，不是失败、不是取消、也不是成功
    private var pendingRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DFColor.inkMuted)
            Text("待恢复 · 重启后自动收尾")
                .font(DFFont.timestamp)
                .foregroundStyle(DFColor.inkMuted)
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if isUser {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(DFColor.surfaceAlt)
                .frame(width: 31, height: 31)
                .overlay(
                    Text("我")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DFColor.inkMuted)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(DFColor.hairline, lineWidth: 1)
                )
        } else if theme.avatarStyle == "initial" {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(DFColor.primary.opacity(0.16))
                .frame(width: 31, height: 31)
                .overlay(
                    Text("鱼")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DFColor.primary)
                )
        } else {
            DFCharacterMark(size: 31)
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if isUser, message.status == .sent {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DFColor.success)
            }
            if message.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(DFColor.primary)
            }
            Text(Self.timeText(for: message.createdAt))
                .font(DFFont.timestamp)
                .foregroundStyle(DFColor.inkMuted)

            if message.editCount > 0 {
                Text("已编辑")
                    .font(DFFont.timestamp)
                    .foregroundStyle(DFColor.inkMuted)
            }

            if isRevoked {
                Text("已撤回")
                    .font(DFFont.timestamp)
                    .foregroundStyle(DFColor.inkMuted)
            }

            if message.status == .sending {
                Text("发送中…")
                    .font(DFFont.timestamp)
                    .foregroundStyle(DFColor.inkMuted)
            }

            if message.status == .canceled {
                Text("已停止")
                    .font(DFFont.timestamp)
                    .foregroundStyle(DFColor.inkMuted)
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func timeText(for millis: Int64) -> String {
        timeFormatter.string(from: Clock.date(fromMillis: millis))
    }
}

/// W2-7 外观设置：主题 / 底色 / 气泡样式 / 字号 / 头像 + 恢复默认。
struct ThemeSettingsSheet: View {
    let onSave: (ChatTheme) -> Void
    let onReset: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ChatTheme

    init(theme: ChatTheme, onSave: @escaping (ChatTheme) -> Void, onReset: @escaping () -> Void) {
        self.onSave = onSave
        self.onReset = onReset
        _draft = State(initialValue: theme)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("主题") {
                    Picker("主题", selection: $draft.themeID) {
                        Text("经典").tag("classic")
                        Text("暖调").tag("warm")
                        Text("夜间").tag("night")
                    }
                    Picker("底色", selection: $draft.background) {
                        Text("奶油").tag("cream")
                        Text("纯净").tag("plain")
                        Text("暗色").tag("dark")
                    }
                }
                Section("气泡") {
                    Picker("气泡样式", selection: $draft.bubbleStyle) {
                        Text("气泡").tag("bubble")
                        Text("纯文字").tag("plain")
                    }
                    Picker("头像", selection: $draft.avatarStyle) {
                        Text("鱼形").tag("fish")
                        Text("文字").tag("initial")
                    }
                    HStack {
                        Text("字号")
                        Slider(value: $draft.fontScale, in: ChatTheme.fontScaleRange, step: 0.05)
                        Text(String(format: "%.0f%%", draft.fontScale * 100))
                            .font(DFFont.caption)
                            .foregroundStyle(DFColor.inkMuted)
                    }
                }
                Section {
                    Button("恢复默认", role: .destructive) {
                        onReset()
                        dismiss()
                    }
                }
            }
            .navigationTitle("外观")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(draft)
                        dismiss()
                    }
                }
            }
        }
    }
}

/// W2-3 编辑消息：保存时写入编辑留痕，原文不丢。
struct EditMessageSheet: View {
    let message: Message
    @Binding var draft: String
    let onCancel: () -> Void
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("编辑后原文会保留在编辑历史里，可随时回查")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.inkMuted)
                TextEditor(text: $draft)
                    .font(DFFont.body)
                    .frame(minHeight: 160)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(DFColor.hairline, lineWidth: 1)
                    )
            }
            .padding(16)
            .navigationTitle("编辑消息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave()
                        dismiss()
                    }
                }
            }
        }
    }
}

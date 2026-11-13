import SwiftUI
import UIKit
import DFCore

@MainActor
struct ChatView: View {
    @StateObject private var viewModel: ChatViewModel
    @FocusState private var isInputFocused: Bool
    private let onOpenSettings: () -> Void

    @MainActor
    init(container: AppContainer, onOpenSettings: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: ChatViewModel(container: container))
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messageList
                composer
            }
            .background(alignment: .top) { chatBackground }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DFColor.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) { headerTitle }
                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.isStreaming {
                        Text("正在输入…")
                            .font(.system(size: 10))
                            .foregroundStyle(DFColor.inkMuted)
                    }
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
        .alert("提示", isPresented: errorBinding) {
            Button("知道了", role: .cancel) {
                viewModel.errorText = nil
            }
        } message: {
            Text(viewModel.errorText ?? "")
        }
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
                            onRetry: { viewModel.retry(message) },
                            onDelete: { viewModel.delete(message) }
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
        }
    }

    /// 页面底色：奶油白 + 顶部柔光 + 鱼鳞暗纹（只到 190pt，向下淡出）
    private var chatBackground: some View {
        ZStack(alignment: .top) {
            DFColor.canvas
            DFSoftGlow()
                .frame(height: 260)
                .clipped()
            DFScaleBackdrop(opacity: 0.16)
                .frame(height: 190)
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
                viewModel.send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(DFColor.bubbleMe, in: Circle())
                    .opacity(canSend ? 1 : 0.4)
            }
            .disabled(!canSend)
            .accessibilityLabel("发送")
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

    private var canSend: Bool {
        !viewModel.isStreaming
            && !viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

@MainActor
struct MessageRow: View {
    let message: Message
    var isStreaming: Bool = false
    let onRetry: () -> Void
    let onDelete: () -> Void

    private var isUser: Bool {
        message.role == .user
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 36) }
            if !isUser { avatar }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                MessageBubble(
                    text: displayText,
                    kind: isUser ? .me : .other,
                    isFailed: message.status == .failed,
                    isStreaming: isStreaming
                )
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = message.text
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    if message.status == .failed {
                        Button(action: onRetry) {
                            Label("重试", systemImage: "arrow.clockwise")
                        }
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("删除", systemImage: "trash")
                    }
                }

                if message.status == .failed {
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
        message.text.isEmpty && message.status == .sending ? "…" : message.text
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
            Text(Self.timeText(for: message.createdAt))
                .font(DFFont.timestamp)
                .foregroundStyle(DFColor.inkMuted)

            if message.status == .sending {
                Text("发送中…")
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

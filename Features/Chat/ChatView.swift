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
                Divider()
                inputBar
            }
            .navigationTitle("大肥鱼")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.isStreaming {
                        Text("正在输入…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                // 键盘上方的收起按钮：iOS 上滑动手势不一定生效，需要一个明确出口
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起") {
                        isInputFocused = false
                    }
                }
            }
        }
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

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if !viewModel.hasModel {
                        emptyBanner
                    }
                    ForEach(viewModel.messages) { message in
                        MessageRow(
                            message: message,
                            onRetry: { viewModel.retry(message) },
                            onDelete: { viewModel.delete(message) }
                        )
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.messages.count) { _, _ in
                guard let last = viewModel.messages.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyBanner: some View {
        VStack(spacing: 8) {
            Text("还没有配置模型")
                .font(.subheadline.weight(.medium))
            Text("先去设置里添加一个 OpenAI 兼容的接口，才能开始聊天。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("去设置") {
                onOpenSettings()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("说点什么…", text: $viewModel.draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($isInputFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Button {
                viewModel.send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
            }
            .disabled(
                viewModel.isStreaming
                    || viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }
}

@MainActor
struct MessageRow: View {
    let message: Message
    let onRetry: () -> Void
    let onDelete: () -> Void

    private var isUser: Bool {
        message.role == .user
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 40) }

            if !isUser { avatar }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                Text(displayText)
                    .font(.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        isUser
                            ? Color.accentColor
                            : Color(uiColor: .secondarySystemGroupedBackground)
                    )
                    .foregroundStyle(isUser ? Color.white : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
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

                footer
            }

            if isUser { avatar }
            if isUser { Spacer(minLength: 0) }
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private var displayText: String {
        message.text.isEmpty && message.status == .sending ? "…" : message.text
    }

    private var avatar: some View {
        Circle()
            .fill(isUser ? Color.gray.opacity(0.25) : Color.accentColor.opacity(0.18))
            .frame(width: 30, height: 30)
            .overlay(
                Text(isUser ? "我" : "鱼")
                    .font(.caption2)
                    .foregroundStyle(isUser ? Color.primary : Color.accentColor)
            )
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 6) {
            Text(Self.timeText(for: message.createdAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)

            switch message.status {
            case .sending:
                Text("发送中…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            case .failed:
                Button(action: onRetry) {
                    Text("发送失败，重试")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            case .sent, .draft, .recalled:
                EmptyView()
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

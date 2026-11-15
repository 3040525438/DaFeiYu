import SwiftUI
import DFCore

/// D57：附件库界面。
///
/// 只做展示、删除确认与批量清理；引用判定与删除语义都在数据层服务里。
@MainActor
struct AttachmentLibraryView: View {
    @StateObject private var viewModel: AttachmentLibraryViewModel
    @State private var showCleanupConfirm = false

    init(container: AppContainer) {
        _viewModel = StateObject(wrappedValue: AttachmentLibraryViewModel(container: container))
    }

    var body: some View {
        List {
            summarySection
            itemsSection
        }
        .listStyle(.insetGrouped)
        .background(DFColor.canvas)
        .navigationTitle("附件库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await viewModel.toggleIncludeDeleted() }
                    } label: {
                        Label(
                            viewModel.includeDeleted ? "隐藏已删除附件" : "显示已删除附件",
                            systemImage: viewModel.includeDeleted ? "eye.slash" : "eye"
                        )
                    }
                    Button {
                        showCleanupConfirm = true
                    } label: {
                        Label("清理未引用附件", systemImage: "trash.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task { await viewModel.reload() }
        .alert("清理未引用附件", isPresented: $showCleanupConfirm) {
            Button("取消", role: .cancel) {}
            Button("清理") {
                Task { await viewModel.cleanupUnreferenced() }
            }
        } message: {
            Text("只清理没有被任何消息引用的附件；仍被引用的会被跳过。删除为软删除，磁盘文件与已生成的文字保留。")
        }
        .alert("删除附件", isPresented: deleteBinding) {
            Button("取消", role: .cancel) { viewModel.pendingDelete = nil }
            if viewModel.pendingDelete?.isInUse == true {
                Button("解除引用并删除", role: .destructive) {
                    if let item = viewModel.pendingDelete {
                        Task { await viewModel.delete(item, force: true) }
                    }
                }
            } else {
                Button("删除", role: .destructive) {
                    if let item = viewModel.pendingDelete {
                        Task { await viewModel.delete(item, force: false) }
                    }
                }
            }
        } message: {
            Text(deleteMessage)
        }
        .fullScreenCover(item: $viewModel.previewing) { item in
            AttachmentPreviewView(
                item: item,
                fileURL: viewModel.fileURL(for: item),
                title: viewModel.fileName(item),
                onClose: { viewModel.previewing = nil }
            )
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { viewModel.pendingDelete != nil },
            set: { if !$0 { viewModel.pendingDelete = nil } }
        )
    }

    private var deleteMessage: String {
        guard let item = viewModel.pendingDelete else { return "" }
        if item.isInUse {
            return "该附件仍被 \(item.liveReferences) 条消息引用。删除会先解除这些消息与附件的关联（消息正文与记忆不受影响）。"
        }
        if item.hasStaleReferencesOnly {
            return "该附件只剩已删除消息的旧关联，可以安全清理。"
        }
        return "该附件没有被任何消息引用，可以安全清理。"
    }

    // MARK: - 概览

    private var summarySection: some View {
        Section {
            HStack(spacing: 12) {
                summaryCell(value: "\(viewModel.items.count)", label: "附件")
                summaryCell(value: viewModel.sizeText(viewModel.totalBytes), label: "占用")
                summaryCell(value: "\(viewModel.inUseCount)", label: "使用中")
            }
            .padding(.vertical, 2)

            if let message = viewModel.lastMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(DFColor.primary)
            }
            if let error = viewModel.errorText {
                Text("⚠︎ \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .listRowBackground(DFColor.surface)
    }

    private func summaryCell(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(DFColor.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(DFColor.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 列表

    @ViewBuilder
    private var itemsSection: some View {
        Section("附件") {
            if viewModel.isLoading && viewModel.items.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            } else if viewModel.items.isEmpty {
                Text("还没有附件。聊天里发送图片、语音或文件后会出现在这里。")
                    .font(.caption)
                    .foregroundStyle(DFColor.inkMuted)
            }
            ForEach(viewModel.items) { item in
                row(item)
                    .listRowBackground(DFColor.surface)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !item.record.isDeleted {
                            Button(role: .destructive) {
                                viewModel.pendingDelete = item
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
            }
        }
    }

    private func row(_ item: AttachmentLibraryItem) -> some View {
        Button {
            if viewModel.canPreview(item) {
                viewModel.openPreview(item)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                thumbnail(item)

                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.fileName(item))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DFColor.ink)
                        .lineLimit(1)
                    Text("\(viewModel.kindText(item.record.kind)) · \(viewModel.sizeText(item.record.byteSize)) · \(Self.dateText(item.record.createdAt))")
                        .font(.caption2)
                        .foregroundStyle(DFColor.inkMuted)
                    Text(capabilityText(item))
                        .font(.caption2)
                        .foregroundStyle(DFColor.inkMuted)
                    HStack(spacing: 6) {
                        Text(viewModel.referenceText(item))
                            .font(.caption2)
                            .foregroundStyle(item.isInUse ? DFColor.primary : DFColor.inkMuted)
                        if item.record.isDeleted {
                            Text("已删除")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(DFColor.surfaceAlt)
                                .foregroundStyle(DFColor.inkMuted)
                                .clipShape(Capsule())
                        }
                    }
                }
                Spacer(minLength: 4)

                if viewModel.canPreview(item) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DFColor.inkMuted)
                        .padding(.top, 8)
                }
            }
        }
        .buttonStyle(.plain)
        .task { await viewModel.loadThumbnailIfNeeded(item) }
        .contextMenu {
            if item.record.kind == "audio" || item.record.kind == "video" {
                Button {
                    Task { await viewModel.retranscribe(item) }
                } label: {
                    Label("重新转写", systemImage: "waveform")
                }
                Button {
                    Task { await viewModel.copyTranscript(item) }
                } label: {
                    Label("复制转写文本", systemImage: "doc.on.doc")
                }
            }
            if viewModel.canShare(item) {
                ShareLink(item: viewModel.fileURL(for: item)) {
                    Label("分享文件", systemImage: "square.and.arrow.up")
                }
            }
            if !item.record.isDeleted {
                Button(role: .destructive) {
                    viewModel.pendingDelete = item
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
    }

    /// D29：如实展示该文件能做什么（保存 / 预览 / 读取文字 / 模型理解）
    private func capabilityText(_ item: AttachmentLibraryItem) -> String {
        let profile = FileCapabilityCatalog.profile(
            fileName: viewModel.fileName(item),
            mime: item.record.mime
        )
        return FileCapabilityCatalog.summary(profile)
    }

    /// D27：图片显示缩略图，其余类型显示类型图标
    @ViewBuilder
    private func thumbnail(_ item: AttachmentLibraryItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DFColor.primarySoft)
            if let image = viewModel.thumbnails[item.id] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: icon(item.record.kind))
                    .font(.system(size: 14))
                    .foregroundStyle(DFColor.primary)
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func icon(_ kind: String) -> String {
        switch kind {
        case "image": return "photo"
        case "audio": return "waveform"
        case "video": return "video"
        default: return "doc"
        }
    }

    private static func dateText(_ millis: Int64) -> String {
        Self.formatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000))
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

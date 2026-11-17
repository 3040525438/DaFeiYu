import SwiftUI
import DFCore

/// 表情面板（D73）：从本地表情库挑一个发给大肥鱼。
///
/// 现有能力边界（如实标注，不假装支持）：
/// - Emoji 表情可直接作为独立消息发送；
/// - 静态图 / GIF 需要附件文件，当前只展示、不发送，避免发出没有内容的空消息；
/// - 在线表情库下载尚未接入，面板里不提供入口，避免"点了没反应"。
@MainActor
struct StickerPanelView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    let onPick: (Sticker) -> Void

    @State private var tab: Tab = .recent
    @State private var stickers: [Sticker] = []
    @State private var isLoading = true
    @State private var errorText: String?

    enum Tab: String, CaseIterable {
        case recent
        case favorites
        case all

        var title: String {
            switch self {
            case .recent: return "最近"
            case .favorites: return "收藏"
            case .all: return "全部"
            }
        }
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Picker("分类", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)
                .onChange(of: tab) { _, _ in
                    Task { await reload() }
                }

                if isLoading {
                    Spacer()
                    ProgressView().tint(DFColor.primary)
                    Spacer()
                } else if stickers.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "face.smiling")
                            .font(.system(size: 22))
                            .foregroundStyle(DFColor.lilac)
                        Text(tab == .recent ? "还没有用过表情" : "这里还没有表情")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DFColor.ink)
                        Text("内置表情会在启动时自动入库；如果这里是空的，稍后重试或重新打开 App。")
                            .font(DFFont.caption)
                            .foregroundStyle(DFColor.inkMuted)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 24)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(stickers) { sticker in
                                Button {
                                    onPick(sticker)
                                    dismiss()
                                } label: {
                                    stickerCell(sticker)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        Task { await toggleFavorite(sticker) }
                                    } label: {
                                        Label(
                                            sticker.isFavorite ? "取消收藏" : "收藏",
                                            systemImage: sticker.isFavorite ? "star.slash" : "star"
                                        )
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 16)
                    }
                }

                if let errorText {
                    Text(errorText)
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.danger)
                        .padding(.horizontal, 14)
                }

                Text("点一下直接发送；长按可收藏。表情会作为独立消息发出，不会打断对话。")
                    .font(.system(size: 10))
                    .foregroundStyle(DFColor.inkMuted)
                    .padding(.bottom, 8)
            }
            .padding(.top, 8)
            .background(DFColor.canvas)
            .navigationTitle("表情包")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task { await reload() }
    }

    private func stickerCell(_ sticker: Sticker) -> some View {
        VStack(spacing: 2) {
            if let emoji = sticker.emoji, !emoji.isEmpty {
                Text(emoji)
                    .font(.system(size: 28))
                    .frame(height: 42)
            } else {
                Image(systemName: sticker.kind == .gif ? "photo.stack" : "photo")
                    .font(.system(size: 20))
                    .foregroundStyle(DFColor.lilac)
                    .frame(height: 42)
            }
            Text(sticker.name)
                .font(.system(size: 8))
                .foregroundStyle(DFColor.inkMuted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(DFColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DFColor.hairline, lineWidth: 1)
        )
    }

    private func toggleFavorite(_ sticker: Sticker) async {
        do {
            try await container.stickers.setFavorite(
                id: sticker.id,
                isFavorite: !sticker.isFavorite,
                at: Clock.nowMillis()
            )
            await reload()
        } catch {
            errorText = "收藏失败：\(error.localizedDescription)"
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            switch tab {
            case .recent:
                stickers = try await container.stickers.recent(limit: 60)
            case .favorites:
                stickers = try await container.stickers.favorites(limit: 60)
            case .all:
                stickers = try await container.stickers.stickers(
                    packID: nil,
                    kind: nil,
                    limit: 200,
                    offset: 0
                )
            }
            errorText = nil
        } catch {
            stickers = []
            errorText = "表情读取失败：\(error.localizedDescription)"
        }
    }
}

import SwiftUI
import DFCore

/// D27：附件原图预览。
///
/// 能力：原图查看、双指/双击放大、拖动平移、系统分享（含"存储图像"）。
/// 边界：只读取本机文件，不发起任何网络请求；文件不在本机时如实提示。
@MainActor
struct AttachmentPreviewView: View {
    let item: AttachmentLibraryItem
    let fileURL: URL
    let title: String
    let onClose: () -> Void

    @State private var image: UIImage?
    @State private var loadFailed = false
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private static let maxScale: CGFloat = 5
    private static let doubleTapScale: CGFloat = 2.5

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(magnification)
                    .simultaneousGesture(drag)
                    .onTapGesture(count: 2) { toggleZoom() }
                    .accessibilityLabel("附件原图")
            } else if loadFailed {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 30))
                    Text("原图不在本机，可能已被清理")
                        .font(DFFont.body)
                }
                .foregroundStyle(.white.opacity(0.8))
            } else {
                ProgressView()
                    .tint(.white)
            }

            VStack {
                topBar
                Spacer()
                bottomBar
            }
        }
        .task { await load() }
        .statusBarHidden(true)
    }

    // MARK: - 手势

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(max(lastScale * value, 1), Self.maxScale)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1 { reset() }
            }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    private func toggleZoom() {
        if scale > 1 {
            reset()
        } else {
            scale = Self.doubleTapScale
            lastScale = scale
        }
    }

    private func reset() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }

    // MARK: - 加载

    private func load() async {
        guard image == nil, !loadFailed else { return }
        let url = fileURL
        let loaded: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
        if let loaded {
            image = loaded
        } else {
            loadFailed = true
        }
    }

    // MARK: - 栏

    private var topBar: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .accessibilityLabel("关闭预览")

            Spacer()

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)

            Spacer()

            if scale > 1 {
                Button {
                    reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.black.opacity(0.35), in: Circle())
                }
                .accessibilityLabel("还原大小")
            } else {
                Color.clear.frame(width: 34, height: 34)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private var bottomBar: some View {
        HStack(spacing: 18) {
            ShareLink(item: fileURL) {
                Label("分享", systemImage: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("双指缩放 · 双击放大")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.bottom, 22)
    }
}

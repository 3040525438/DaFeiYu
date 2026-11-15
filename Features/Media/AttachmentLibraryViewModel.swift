import Foundation
import DFCore

/// D57：附件库与清理。
///
/// 删除一律走 `AttachmentReferenceService`：
/// - 被活消息引用时默认拒绝，必须用户显式确认才强制解除引用；
/// - 批量清理只处理无活引用的附件，被引用的跳过并如实回报。
@MainActor
final class AttachmentLibraryViewModel: ObservableObject {
    @Published private(set) var items: [AttachmentLibraryItem] = []
    @Published var includeDeleted = false
    @Published private(set) var isLoading = false
    @Published var errorText: String?
    @Published private(set) var lastMessage: String?
    /// 待确认删除的附件
    @Published var pendingDelete: AttachmentLibraryItem?

    private let container: AppContainer

    init(container: AppContainer) {
        self.container = container
    }

    var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.record.byteSize }
    }

    var inUseCount: Int {
        items.filter(\.isInUse).count
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await container.attachmentReferences.library(
                includeDeleted: includeDeleted,
                limit: 200,
                offset: 0
            )
            errorText = nil
        } catch {
            errorText = Self.message(error)
        }
    }

    func toggleIncludeDeleted() async {
        includeDeleted.toggle()
        await reload()
    }

    /// 删除单条附件。`force == true` 表示用户已确认解除引用。
    func delete(_ item: AttachmentLibraryItem, force: Bool) async {
        do {
            try await container.attachmentReferences.deleteAttachment(
                id: item.record.id,
                at: Clock.nowMillis(),
                force: force
            )
            pendingDelete = nil
            await reload()
            lastMessage = "已删除附件（磁盘文件与派生文本保留，可恢复）"
        } catch let error as AttachmentReferenceError {
            // 被引用：转成确认流程，不静默失败
            if case .inUse = error {
                pendingDelete = item
                errorText = error.description
            } else {
                errorText = error.description
            }
        } catch {
            errorText = Self.message(error)
        }
    }

    /// 批量清理：先取"早于现在且完全没有关联"的候选，再交给服务逐个复核引用。
    func cleanupUnreferenced() async {
        do {
            let now = Clock.nowMillis()
            let candidates = try await container.attachmentReferences.cleanupCandidates(
                before: now,
                limit: 200
            )
            guard !candidates.isEmpty else {
                lastMessage = "没有可清理的未引用附件"
                return
            }
            let result = try await container.attachmentReferences.cleanup(
                attachmentIDs: candidates.map(\.id),
                at: now
            )
            await reload()
            lastMessage = "已清理 \(result.deleted) 个附件"
                + (result.skippedInUse > 0 ? "，跳过 \(result.skippedInUse) 个仍被引用的" : "")
        } catch {
            errorText = Self.message(error)
        }
    }

    func clearLastMessage() {
        lastMessage = nil
    }

    // MARK: - 展示辅助

    func sizeText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    func kindText(_ kind: String) -> String {
        switch kind {
        case "image": return "图片"
        case "audio": return "语音"
        case "video": return "视频"
        case "file": return "文件"
        default: return kind
        }
    }

    func referenceText(_ item: AttachmentLibraryItem) -> String {
        if item.isInUse {
            return "使用中 · \(item.liveReferences) 条消息引用"
        }
        if item.hasStaleReferencesOnly {
            return "仅剩已删除消息的旧引用（\(item.totalReferences)）"
        }
        return "未引用"
    }

    private static func message(_ error: Error) -> String {
        if let reference = error as? AttachmentReferenceError { return reference.description }
        if let dfError = error as? DFError, let text = dfError.errorDescription { return text }
        return error.localizedDescription
    }
}

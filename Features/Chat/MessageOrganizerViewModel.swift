import Foundation
import DFCore

/// D26：消息整理。
///
/// 只调用 `MessageOrganizationRepository`（收藏 / 重要 / 标签）与 `MessageRepository`（读正文），
/// **不写记忆、不改人格**：整理只是给消息加标记，供检索与管理使用。
@MainActor
final class MessageOrganizerViewModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        var message: Message
        var tags: [String]

        var id: String { message.id }
    }

    @Published var filter: MessageFilter = .favorite
    @Published private(set) var items: [Item] = []
    @Published var selection: Set<String> = []
    @Published private(set) var tagSummary: [MessageTagCount] = []
    @Published private(set) var isLoading = false
    @Published var errorText: String?
    /// 最近一次操作结果（成功或失败），供视图以 banner 形式展示
    @Published private(set) var lastMessage: String?

    private let container: AppContainer
    private let pageSize = 100

    init(container: AppContainer) {
        self.container = container
    }

    var maxTagLength: Int { container.messageOrganization.tagLimit }

    var filterTitle: String {
        switch filter {
        case .all: return "全部消息"
        case .favorite: return "收藏"
        case .important: return "重要"
        case .tagged(let tag): return "标签 · \(tag)"
        }
    }

    var selectionCount: Int { selection.count }

    func reload() async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            let ids = try await container.messageOrganization.messageIDs(
                filter: filter,
                limit: pageSize,
                offset: 0
            )
            var loaded: [Item] = []
            for id in ids {
                guard let message = try await container.messages.message(id: id) else { continue }
                let tags = (try? await container.messageOrganization.tags(ofMessage: id)) ?? []
                loaded.append(Item(message: message, tags: tags))
            }
            items = loaded
            selection = selection.intersection(Set(ids))
            tagSummary = (try? await container.messageOrganization.tagSummary()) ?? []
        } catch {
            errorText = Self.message(error)
        }
    }

    // MARK: - 选择

    func toggleSelection(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    func selectAll() {
        selection = Set(items.map(\.id))
    }

    func clearSelection() {
        selection.removeAll()
    }

    var selectedIDs: [String] { selection.sorted() }

    // MARK: - 批量操作

    func setFavorite(_ favorite: Bool) async {
        guard !selection.isEmpty else { return }
        do {
            let changed = try await container.messageOrganization.setFavoriteBatch(
                ids: selectedIDs,
                isFavorite: favorite,
                at: Clock.nowMillis()
            )
            await reload()
            errorText = nil
            report(favorite ? "已收藏 \(changed) 条" : "已取消收藏 \(changed) 条")
        } catch {
            errorText = Self.message(error)
        }
    }

    func setImportant(_ important: Bool) async {
        guard !selection.isEmpty else { return }
        let ids = selectedIDs
        do {
            for id in ids {
                try await container.messageOrganization.setImportant(
                    id: id,
                    isImportant: important,
                    at: Clock.nowMillis()
                )
            }
            await reload()
            errorText = nil
            report(important ? "已标记重要 \(ids.count) 条" : "已取消重要标记 \(ids.count) 条")
        } catch {
            errorText = Self.message(error)
        }
    }

    func addTag(_ rawTag: String) async {
        let tag = normalize(rawTag)
        guard !tag.isEmpty else {
            errorText = MessageOrganizationError.emptyTag.description
            return
        }
        guard tag.count <= maxTagLength else {
            errorText = MessageOrganizationError.tagTooLong(maxTagLength).description
            return
        }
        guard !selection.isEmpty else { return }
        do {
            let added = try await container.messageOrganization.addTag(
                tag,
                to: selectedIDs,
                at: Clock.nowMillis()
            )
            await reload()
            errorText = nil
            report(added > 0 ? "已为 \(added) 条消息添加标签「\(tag)」" : "这些消息已有标签「\(tag)」")
        } catch {
            errorText = Self.message(error)
        }
    }

    func removeTag(_ rawTag: String) async {
        let tag = normalize(rawTag)
        guard !tag.isEmpty else {
            errorText = MessageOrganizationError.emptyTag.description
            return
        }
        guard !selection.isEmpty else { return }
        do {
            let removed = try await container.messageOrganization.removeTag(tag, from: selectedIDs)
            await reload()
            errorText = nil
            report(removed > 0 ? "已移除 \(removed) 条标签「\(tag)」" : "这些消息没有标签「\(tag)」")
        } catch {
            errorText = Self.message(error)
        }
    }

    // MARK: - 内部

    /// 与数据层保持一致的归一化口径：去首尾空白、去前导 #、折叠连续空白
    private func normalize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("#") {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespaces)
        }
        return text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func report(_ text: String) {
        lastMessage = text
    }

    func clearLastMessage() {
        lastMessage = nil
    }

    private static func message(_ error: Error) -> String {
        if let organization = error as? MessageOrganizationError { return organization.description }
        if let dfError = error as? DFError, let text = dfError.errorDescription { return text }
        return error.localizedDescription
    }
}

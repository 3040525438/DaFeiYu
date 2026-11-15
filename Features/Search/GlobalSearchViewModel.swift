import Foundation
import DFCore

/// D25：全局搜索。
///
/// 只做"查询 + 分组 + 打开详情"，检索口径全部在 `UnifiedSearchRepository` 里，
/// 界面不自行拼 SQL、也不改写摘要。
@MainActor
final class GlobalSearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published private(set) var hits: [UnifiedSearchHit] = []
    @Published private(set) var isSearching = false
    @Published private(set) var hasSearched = false
    @Published var errorText: String?
    /// 参与检索的域；全不选时界面明确提示，而不是静默返回空
    @Published var enabledDomains: Set<SearchDomain> = Set(SearchDomain.allCases)

    private let container: AppContainer

    init(container: AppContainer) {
        self.container = container
    }

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 按固定域顺序分组，空组不显示
    var grouped: [GlobalSearchGroup] {
        SearchDomain.allCases.compactMap { domain in
            let items = hits.filter { $0.domain == domain }
            return items.isEmpty ? nil : GlobalSearchGroup(domain: domain, hits: items)
        }
    }

    func isEnabled(_ domain: SearchDomain) -> Bool {
        enabledDomains.contains(domain)
    }

    func toggle(_ domain: SearchDomain) {
        if enabledDomains.contains(domain) {
            enabledDomains.remove(domain)
        } else {
            enabledDomains.insert(domain)
        }
    }

    func search() async {
        let text = trimmedQuery
        guard !text.isEmpty else {
            hits = []
            hasSearched = false
            errorText = nil
            return
        }
        guard !enabledDomains.isEmpty else {
            hits = []
            hasSearched = true
            errorText = "请至少选择一个搜索范围"
            return
        }

        isSearching = true
        errorText = nil
        defer { isSearching = false }
        do {
            let result = try await container.unifiedSearch.search(
                query: text,
                domains: enabledDomains,
                limitPerDomain: 20
            )
            hits = result
            hasSearched = true
        } catch {
            hits = []
            hasSearched = true
            errorText = Self.message(error)
        }
    }

    func clear() {
        query = ""
        hits = []
        hasSearched = false
        errorText = nil
    }

    // MARK: - 打开详情

    /// 非消息命中：读取完整正文用于详情页。消息命中由聊天页负责跳转定位。
    func detail(for hit: UnifiedSearchHit) async -> GlobalSearchDetail? {
        do {
            switch hit.domain {
            case .memory:
                guard let record = try await container.memories.memory(id: hit.targetID) else {
                    return nil
                }
                return GlobalSearchDetail(
                    title: record.title,
                    body: record.content,
                    source: "记忆 · 重要度 \(record.importance)"
                )
            case .diary:
                guard let entry = try await container.diary.entry(id: hit.targetID) else {
                    return nil
                }
                return GlobalSearchDetail(
                    title: entry.title.isEmpty ? entry.entryDate : entry.title,
                    body: entry.content,
                    source: "日记 · \(entry.entryDate)"
                )
            case .attachment:
                return GlobalSearchDetail(
                    title: hit.title,
                    body: hit.snippet,
                    source: "附件文字索引（片段）"
                )
            case .message:
                return GlobalSearchDetail(
                    title: hit.title,
                    body: hit.snippet,
                    source: "聊天消息（片段）"
                )
            }
        } catch {
            errorText = Self.message(error)
            return nil
        }
    }

    private static func message(_ error: Error) -> String {
        if let dfError = error as? DFError, let text = dfError.errorDescription { return text }
        return error.localizedDescription
    }
}

/// 搜索详情（只读展示）
struct GlobalSearchDetail: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var body: String
    var source: String
}

/// 按域分组的搜索结果
struct GlobalSearchGroup: Identifiable {
    var domain: SearchDomain
    var hits: [UnifiedSearchHit]

    var id: String { domain.rawValue }
}

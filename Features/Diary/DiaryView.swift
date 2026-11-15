import SwiftUI
import DFCore

/// 日记情绪标签（与数据库 `mood_code` 对应，仅用于展示与选择）
enum DiaryMood: String, CaseIterable, Identifiable {
    case calm
    case warm
    case happy
    case tired
    case low
    case excited

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calm: return "平静"
        case .warm: return "温柔"
        case .happy: return "开心"
        case .tired: return "疲惫"
        case .low: return "低落"
        case .excited: return "雀跃"
        }
    }

    static func mood(for code: String?) -> DiaryMood? {
        guard let code else { return nil }
        return DiaryMood(rawValue: code)
    }
}

/// 日记列表：按日期倒序回顾，支持新建 / 编辑。
/// 结构化字段（共同经历 / 观察 / 感受 / 关系变化）来自 v12，历史日记保持为空，不补写。
@MainActor
struct DiaryView: View {
    @EnvironmentObject private var container: AppContainer

    @State private var entries: [DiaryEntry] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var route: DiaryEditorRoute?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                introCard

                if isLoading {
                    ProgressView()
                        .tint(DFColor.primary)
                        .padding(.top, 24)
                } else if let loadError {
                    errorCard(loadError)
                } else if entries.isEmpty {
                    emptyCard
                } else {
                    ForEach(entries) { entry in
                        Button {
                            route = .edit(entry)
                        } label: {
                            entryCard(entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(alignment: .top) { pageBackground }
        .navigationTitle("日记")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(DFColor.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    route = .create(Self.todayText())
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("写今天的日记")
            }
        }
        .task { await reload() }
        .sheet(item: $route) { route in
            NavigationStack {
                switch route {
                case .create(let date):
                    DiaryEditorView(date: date, existing: nil) { await reload() }
                        .environmentObject(container)
                case .edit(let entry):
                    DiaryEditorView(date: entry.entryDate, existing: entry) { await reload() }
                        .environmentObject(container)
                }
            }
        }
    }

    // MARK: - 数据

    private func reload() async {
        do {
            entries = try await container.diary.entries(
                from: "1970-01-01",
                to: "9999-12-31",
                limit: 365
            )
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    static func todayText() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func displayDate(_ value: String) -> String {
        let parts = value.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) else {
            return value
        }
        return "\(month)月\(day)日"
    }

    // MARK: - 卡片

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("她的日记本")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DFColor.ink)
            Text("用第一人称写下共同经历、观察、感受和关系变化；关系变化只有你确认后才算数。")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.inkMuted)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(DFColor.lilacSoft)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous)
                .stroke(DFColor.lilac.opacity(0.4), lineWidth: 1)
        )
    }

    private var emptyCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "book.closed")
                .font(.system(size: 22))
                .foregroundStyle(DFColor.primary)
            Text("还没有日记")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DFColor.ink)
            Text("点右上角写下今天。内容只保存在本机，不会上传。")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.inkMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(DFColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.panel, style: .continuous)
                .stroke(DFColor.hairline, lineWidth: 1)
        )
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("日记读取失败")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DFColor.danger)
            Text(message)
                .font(DFFont.caption)
                .foregroundStyle(DFColor.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(DFColor.dangerSoft)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous))
    }

    private func entryCard(_ entry: DiaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(Self.displayDate(entry.entryDate))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DFColor.ink)

                if let mood = DiaryMood.mood(for: entry.moodCode) {
                    Text(mood.title)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(DFColor.primaryDeep)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(DFColor.primarySoft, in: Capsule())
                }

                Spacer()

                if entry.memoryID != nil {
                    Text("已沉淀")
                        .font(.system(size: 9))
                        .foregroundStyle(DFColor.success)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(DFColor.success.opacity(0.12), in: Capsule())
                }
            }

            if !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(entry.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DFColor.ink)
                    .lineLimit(1)
            }

            Text(entry.content)
                .font(DFFont.caption)
                .foregroundStyle(DFColor.inkMuted)
                .lineLimit(4)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if entry.hasStructuredNotes {
                HStack(spacing: 5) {
                    if !entry.sharedExperience.isEmpty { tag("共同经历") }
                    if !entry.observation.isEmpty { tag("观察") }
                    if !entry.feeling.isEmpty { tag("感受") }
                    if !entry.relationshipChange.isEmpty { tag("关系变化") }
                }
            }

            if entry.needsRelationshipConfirmation {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 10))
                    Text("关系变化待你确认")
                        .font(.system(size: 10))
                }
                .foregroundStyle(DFColor.warning)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DFColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous)
                .stroke(DFColor.hairline, lineWidth: 1)
        )
    }

    private func tag(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9))
            .foregroundStyle(DFColor.inkMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(DFColor.surfaceAlt, in: Capsule())
    }

    private var pageBackground: some View {
        ZStack(alignment: .top) {
            DFColor.canvas
            DFSoftGlow()
                .frame(height: 220)
                .clipped()
        }
        .ignoresSafeArea()
    }
}

/// 编辑器入口：新建（指定日期）或编辑已有日记
enum DiaryEditorRoute: Identifiable {
    case create(String)
    case edit(DiaryEntry)

    var id: String {
        switch self {
        case .create(let date): return "create-\(date)"
        case .edit(let entry): return entry.id
        }
    }
}

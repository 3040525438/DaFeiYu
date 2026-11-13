import Foundation
import DFCore

/// 陪伴统计：全部来自本地数据库，不做任何推断。
/// 记忆 / 成长 / 空间三个页面共用，避免各写一套读取逻辑。
struct CompanionStats {
    var dayCount: Int = 1
    var messageCount: Int = 0
    var startedAt: Date?
    var lastMessageAt: Date?

    /// 在 MainActor 上读取：AppContainer 不是 Sendable，避免跨隔离域传递。
    @MainActor
    static func load(container: AppContainer) async -> CompanionStats {
        var stats = CompanionStats()
        do {
            let conversation = try await container.conversations
                .ensureMainConversation(title: "大肥鱼")
            stats.messageCount = try await container.messages.count(in: conversation.id)
            stats.startedAt = Clock.date(fromMillis: conversation.createdAt)
            if let last = try await container.messages
                .recentMessages(in: conversation.id, limit: 1).last {
                stats.lastMessageAt = Clock.date(fromMillis: last.createdAt)
            }
        } catch {
            // 读失败时保持零值并显示空态，不弹窗打断用户
            NSLog("读取陪伴统计失败：\(error.localizedDescription)")
        }
        stats.dayCount = dayCount(since: stats.startedAt)
        return stats
    }

    static func dayCount(since date: Date?) -> Int {
        guard let date else { return 1 }
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: Date())
        ).day ?? 0
        return max(days + 1, 1)
    }

    static func dateText(_ date: Date?) -> String {
        guard let date else { return "—" }
        return dayFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

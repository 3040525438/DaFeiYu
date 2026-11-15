import Foundation
import UserNotifications
import DFCore
import DFData

/// 主动消息的系统通知投递（D48 / N-08）。
///
/// 边界：
/// - `hidden` 一律不投递；
/// - `brief` 只显示提示语，不把正文放到锁屏；
/// - `full` 显示正文（超长截断）；
/// - 未授权或系统拒绝时不抛错，返回结果由界面解释原因；
/// - 投递只依赖已落库的主动消息，不在这里生成内容。
final class ProactiveNotificationService: @unchecked Sendable {
    enum DeliverOutcome: Equatable {
        case delivered
        case skippedHidden
        case notAuthorized
        case failed(String)
    }

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// 请求授权；返回是否拿到可用授权。
    @discardableResult
    func requestAuthorization() async -> Bool {
        let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        return granted
    }

    @discardableResult
    func deliver(_ message: ProactiveMessage) async -> DeliverOutcome {
        guard message.notifyLevel != .hidden else { return .skippedHidden }

        let status = await authorizationStatus()
        guard status == .authorized || status == .provisional || status == .ephemeral else {
            return .notAuthorized
        }

        let content = UNMutableNotificationContent()
        content.title = "大肥鱼"
        switch message.notifyLevel {
        case .full:
            content.body = String(message.text.prefix(120))
        case .brief:
            content.body = "她想和你说句话，点开看看。"
        case .hidden:
            return .skippedHidden
        }
        content.sound = .default
        content.threadIdentifier = "proactive"
        content.userInfo = ["proactive_id": message.id]

        let request = UNNotificationRequest(
            identifier: Self.notificationID(for: message.id),
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            return .delivered
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 撤销某条主动消息的通知（用户在前台看过时调用）。
    func withdraw(id: String) {
        let identifier = Self.notificationID(for: id)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    /// 待投递的主动消息通知数量。
    func pendingCount() async -> Int {
        await center.pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix(Self.prefix) }
            .count
    }

    /// 清空所有主动消息通知（待投递与已送达）。
    func clearAll() {
        center.removeAllDeliveredNotifications()
        Task {
            let identifiers = await center.pendingNotificationRequests()
                .map(\.identifier)
                .filter { $0.hasPrefix(Self.prefix) }
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
        }
    }

    static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "尚未请求授权"
        case .denied: return "已被拒绝，需要在系统设置里开启"
        case .authorized: return "已授权"
        case .provisional: return "临时授权（静默投递到通知中心）"
        case .ephemeral: return "临时授权（App Clip）"
        @unknown default: return "未知状态"
        }
    }

    private static let prefix = "proactive-"

    private static func notificationID(for proactiveID: String) -> String {
        prefix + proactiveID
    }
}

import UserNotifications

/// iOS 默认在 App 处于前台时不显示任何通知横幅（静默进通知中心）。
/// 用户在通知设置页点"发送测试通知"时 App 正在前台，因此看起来"没有反应"。
///
/// 这个 delegate 让前台也能弹出横幅、进入通知列表并带声音；
/// 未实现 didReceive，点击通知的系统默认行为保持不变。
final class ForegroundNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ForegroundNotificationPresenter()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

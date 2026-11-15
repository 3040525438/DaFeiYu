import Foundation
import BackgroundTasks
import DFCore

/// 线程安全的容器持有者：后台任务回调在系统线程，需要拿到启动阶段装配好的容器。
final class ContainerHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AppContainer?

    func set(_ container: AppContainer?) {
        lock.lock()
        value = container
        lock.unlock()
    }

    func get() -> AppContainer? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// 后台刷新（N-07 / D50）：系统唤醒时做任务补算与过期清理。
///
/// 边界：
/// - 只做幂等的补算与清理，不生成新的主动内容（意图生成见 N-20，仍未接入）；
/// - 注册必须发生在应用启动早期，否则系统会拒绝；
/// - 每次处理完立即排下一次，处理失败也排，避免被系统降频后再也不跑；
/// - 容器还没装配好时直接失败，不写入任何数据。
final class BackgroundRefreshService: @unchecked Sendable {
    static let taskIdentifier = "com.dafeiyu.autonomy.refresh"

    private let holder: ContainerHolder
    private let queue = DispatchQueue(label: "com.dafeiyu.background-refresh")

    init(holder: ContainerHolder) {
        self.holder = holder
    }

    /// 在 App 启动早期调用一次。
    func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: queue
        ) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.handle(refreshTask)
        }
    }

    /// 进入后台时安排下一次刷新。
    func schedule(earliestInSeconds: TimeInterval = 15 * 60) {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliestInSeconds)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NSLog("后台刷新安排失败：\(error.localizedDescription)")
        }
    }

    private func handle(_ task: BGAppRefreshTask) {
        // 先排下一次，保证即使本次超时也不会断链
        schedule()

        let work = Task { [holder] in
            guard let container = holder.get() else {
                task.setTaskCompleted(success: false)
                return
            }
            var success = true
            do {
                _ = try await container.autonomy.expireStale()
                _ = try await container.autonomy.backfill()
            } catch {
                success = false
            }
            task.setTaskCompleted(success: success)
        }

        task.expirationHandler = {
            work.cancel()
        }
    }
}

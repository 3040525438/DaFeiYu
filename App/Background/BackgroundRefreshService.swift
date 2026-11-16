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

/// 后台刷新（N-07 / D09 / N-20）：系统唤醒时做补算、过期清理、自动备份与主动意图。
///
/// 边界：
/// - 补算与清理幂等；自动备份受 D09 策略约束（每日一次完整、变更后增量，有最小间隔）；
/// - 主动意图只处理 message / suggestion 两类任务，必须通过五重闸门才会写入会话；
/// - 注册必须发生在应用启动早期，否则系统会拒绝；
/// - 每次处理完立即排下一次，处理失败也排，避免被系统降频后再也不跑；
/// - 容器还没装配好时直接失败，不写入任何数据。
final class BackgroundRefreshService: @unchecked Sendable {
    static let taskIdentifier = "com.dafeiyu.autonomy.refresh"
    /// 每日日记：目标 23:00 之后，但触发时刻由系统决定（不保证准点）
    static let diaryTaskIdentifier = "com.dafeiyu.diary.daily"

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
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.diaryTaskIdentifier,
            using: queue
        ) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.handleDiary(refreshTask)
        }
    }

    /// 安排下一次日记生成：`earliestBeginDate` = 今天（或明天）的 23:00。
    ///
    /// 注意：这只是"最早可以开始"的时间，系统可能晚很多才唤醒；真正的补齐靠启动/回前台补偿。
    func scheduleDiary(nowMillis: Int64 = Clock.nowMillis()) {
        guard let next = DiarySchedulePolicy.nextTrigger(after: nowMillis) else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.diaryTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSince1970: Double(next) / 1000)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NSLog("日记后台任务安排失败：\(error.localizedDescription)")
        }
    }

    private func handleDiary(_ task: BGAppRefreshTask) {
        // 先排下一次，保证即使这次失败也不会断链
        scheduleDiary()

        let work = Task { [holder] in
            guard let container = holder.get() else {
                task.setTaskCompleted(success: false)
                return
            }
            let reports = await container.runDiaryCompensation()
            // 有失败就上报 false，系统会更早再次唤醒
            let failed = reports.contains { $0.status == .failed }
            task.setTaskCompleted(success: !failed)
        }
        task.expirationHandler = {
            work.cancel()
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
            do {
                _ = try await container.backupScheduler.runIfDue()
            } catch {
                NSLog("自动备份失败：\(error.localizedDescription)")
            }
            // N-20：先按"久未说话"规则排任务，再生成意图 → 五重闸门 → 写会话 → 通知
            _ = try? await container.proactiveScheduler.enqueueDueCheckIn()
            // D47：每天最多一次"是否值得开新会话"的评估（模型判断 + 策略去重）
            _ = try? await container.proactiveScheduler.enqueueNewConversationIfDue()
            _ = await ProactiveIntentRunner(container: container).runDueIntents(limit: 2)
            task.setTaskCompleted(success: success)
        }

        task.expirationHandler = {
            work.cancel()
        }
    }
}

import SwiftUI
import UIKit
import UserNotifications
import DFCore

/// 通知设置（N-08）：授权、通知档位说明、链路自检与清空。
///
/// 说明：主动消息链路（N-20）已接入，真正投递由 `ProactiveIntentRunner` 在后台决定；
/// “发送测试通知”只验证系统通道，不会写主动消息表。
@MainActor
struct NotificationSettingsView: View {
    @EnvironmentObject private var container: AppContainer

    @State private var status: UNAuthorizationStatus = .notDetermined
    @State private var pendingCount = 0
    @State private var message: String?
    @State private var isWorking = false
    /// 真实策略（D13 / D14 / D48）：通知档位、免打扰、最小间隔、每日上限都写回 settings
    @State private var policy: AutonomyPolicy = .default
    @State private var policyError: String?

    var body: some View {
        List {
            statusSection
            policySection
            actionSection
            noteSection
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(16)
        .scrollContentBackground(.hidden)
        .background(DFColor.canvas)
        .tint(DFColor.primary)
        .navigationTitle("通知")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            LabeledContent("系统授权", value: ProactiveNotificationService.describe(status))
            LabeledContent("待投递", value: "\(pendingCount) 条")
            if status == .denied {
                Button("去系统设置开启") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            }
        } header: {
            Text("状态")
        }
    }

    private var policySection: some View {
        Section {
            Toggle("允许主动行为", isOn: Binding(
                get: { policy.enabled },
                set: { policy.enabled = $0; savePolicy() }
            ))

            Picker("通知档位", selection: Binding(
                get: { policy.notificationLevel },
                set: { policy.notificationLevel = $0; savePolicy() }
            )) {
                Text("完整内容").tag(NotificationLevel.full)
                Text("简短提示").tag(NotificationLevel.brief)
                Text("不通知").tag(NotificationLevel.hidden)
            }
            .pickerStyle(.segmented)

            DatePicker("免打扰开始", selection: quietStartDate, displayedComponents: .hourAndMinute)
            DatePicker("免打扰结束", selection: quietEndDate, displayedComponents: .hourAndMinute)

            Stepper(
                "最小间隔 \(policy.minIntervalMinutes) 分钟",
                value: Binding(
                    get: { policy.minIntervalMinutes },
                    set: { policy.minIntervalMinutes = $0; savePolicy() }
                ),
                in: 15...720,
                step: 15
            )

            Stepper(
                "每日上限 \(policy.dailyLimit) 条",
                value: Binding(
                    get: { policy.dailyLimit },
                    set: { policy.dailyLimit = $0; savePolicy() }
                ),
                in: 1...20
            )

            if let policyError {
                Text(policyError)
                    .font(.caption)
                    .foregroundStyle(DFColor.danger)
            }
        } header: {
            Text("主动行为与通知")
        } footer: {
            Text("这些值会真正写入自主策略并参与发送闸门，不是界面上的临时开关。免打扰支持跨午夜（默认 23:00–08:00），最小间隔默认 120 分钟，每日上限默认 5 条。")
        }
    }

    private var actionSection: some View {
        Section {
            Button("请求通知授权") {
                Task { await requestAuthorization() }
            }
            .disabled(isWorking)

            Button("发送测试通知") {
                Task { await sendTest() }
            }
            .disabled(isWorking)

            Button("清除所有通知", role: .destructive) {
                container.notifications.clearAll()
                message = "已清除通知"
                Task { await refresh() }
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("操作")
        }
    }

    private var noteSection: some View {
        Section {
            Text("主动消息由后台任务按策略生成并投递；测试通知只验证系统通道，不会写入聊天记录。")
        } footer: {
            Text("通知开关始终尊重系统授权；被拒绝时不会绕过，也不会静默改设置。")
        }
    }

    // MARK: - 动作

    private func refresh() async {
        status = await container.notifications.authorizationStatus()
        pendingCount = await container.notifications.pendingCount()
        if let state = try? await container.autonomy.state() {
            policy = state.policy
        }
    }

    // MARK: - 策略读写

    private var quietStartDate: Binding<Date> { minutesBinding(\.quietStartMinute) }
    private var quietEndDate: Binding<Date> { minutesBinding(\.quietEndMinute) }

    private func minutesBinding(_ keyPath: WritableKeyPath<AutonomyPolicy, Int>) -> Binding<Date> {
        Binding(
            get: { Self.date(minutes: policy[keyPath: keyPath]) },
            set: { newValue in
                policy[keyPath: keyPath] = Self.minutes(date: newValue)
                savePolicy()
            }
        )
    }

    /// 控件一改就落库；失败只提示，不改回旧值以免用户输入被吞
    private func savePolicy() {
        let snapshot = policy
        Task {
            do {
                try await container.autonomy.savePolicy(snapshot)
                policyError = nil
            } catch {
                policyError = "保存失败：\(error.localizedDescription)"
            }
        }
    }

    private static func date(minutes: Int) -> Date {
        let calendar = Calendar.current
        let base = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .minute, value: max(0, min(minutes, 1439)), to: base) ?? base
    }

    private static func minutes(date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private func requestAuthorization() async {
        isWorking = true
        defer { isWorking = false }
        let granted = await container.notifications.requestAuthorization()
        await refresh()
        message = granted ? "已获得通知授权" : "没有拿到授权：\(ProactiveNotificationService.describe(status))"
    }

    private func sendTest() async {
        isWorking = true
        defer { isWorking = false }

        let now = Clock.nowMillis()
        let sample = ProactiveMessage(
            id: UUID().uuidString,
            intentID: nil,
            plannedAt: now,
            text: "这是一条测试通知：通道正常，内容不会写入聊天记录。",
            isVoice: false,
            status: .planned,
            suppressReason: nil,
            notificationID: nil,
            resolvedAt: nil,
            priority: 3,
            expiresAt: nil,
            dedupeKey: nil,
            messageID: nil,
            sentAt: nil,
            characterID: nil,
            moodCode: nil,
            notifyLevel: policy.notificationLevel,
            feedback: .none,
            feedbackAt: nil,
            isFavorite: false,
            triggerKind: "test",
            triggerRef: nil
        )

        switch await container.notifications.deliver(sample) {
        case .delivered:
            message = "测试通知已投递"
        case .skippedHidden:
            message = "当前档位为“不通知”，没有投递"
        case .notAuthorized:
            message = "未获得授权，请先请求授权或在系统设置里开启"
        case .failed(let reason):
            message = "投递失败：\(reason)"
        }
        await refresh()
    }
}

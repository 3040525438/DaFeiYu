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
    @State private var level: NotificationLevel = .brief
    @State private var isWorking = false

    var body: some View {
        List {
            statusSection
            levelSection
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

    private var levelSection: some View {
        Section {
            Picker("通知档位", selection: $level) {
                Text("完整内容").tag(NotificationLevel.full)
                Text("简短提示").tag(NotificationLevel.brief)
                Text("不通知").tag(NotificationLevel.hidden)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("档位")
        } footer: {
            Text("完整内容会显示正文；简短提示只说“她想和你说句话”；不通知则完全不出现在锁屏。默认简短提示。")
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
            notifyLevel: level,
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

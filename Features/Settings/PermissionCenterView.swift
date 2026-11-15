import SwiftUI
import UIKit
import AVFoundation
import Speech
import UserNotifications
import DFCore

/// D69：权限中心。
///
/// 只做三件事：展示真实系统状态、解释用途与替代方案、在用户点按时才申请。
/// **不会在页面出现时自动弹授权框**（启动与进入本页都不申请）。
@MainActor
struct PermissionCenterView: View {
    @EnvironmentObject private var container: AppContainer

    @State private var statuses: [AppPermission: PermissionStatus] = [:]
    @State private var working: AppPermission?
    @State private var message: String?

    private var advices: [PermissionAdvice] {
        PermissionAdvisor.advices(statuses)
    }

    var body: some View {
        List {
            Section {
                ForEach(advices, id: \.permission) { advice in
                    row(advice)
                }
            } header: {
                Text("权限")
            } footer: {
                Text("大肥鱼只在你真正使用对应功能时申请权限，启动和打开本页都不会弹窗。")
            }

            if let message {
                Section {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("权限")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
    }

    // MARK: - 行

    @ViewBuilder
    private func row(_ advice: PermissionAdvice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(advice.permission.displayName)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(advice.status.displayName)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(statusColor(advice.status).opacity(0.15), in: Capsule())
                    .foregroundStyle(statusColor(advice.status))
            }
            Text(advice.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(advice.purpose)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if !advice.isUsable {
                Text("替代方案：\(advice.alternative)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            actionButton(advice)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func actionButton(_ advice: PermissionAdvice) -> some View {
        switch advice.action {
        case .request:
            Button {
                Task { await request(advice.permission) }
            } label: {
                Text("申请\(advice.permission.displayName)权限")
                    .font(.footnote)
            }
            .disabled(working != nil)
        case .openSettings:
            Button {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            } label: {
                Text("去系统设置")
                    .font(.footnote)
            }
        case .none:
            EmptyView()
        }
    }

    private func statusColor(_ status: PermissionStatus) -> Color {
        switch status {
        case .granted: return .green
        case .limited: return .orange
        case .denied, .restricted: return .red
        case .notDetermined: return .secondary
        }
    }

    // MARK: - 状态与申请

    private func refresh() async {
        statuses = [
            .notifications: Self.notificationStatus(await container.notifications.authorizationStatus()),
            .microphone: Self.microphoneStatus(),
            .speechRecognition: Self.speechStatus()
        ]
    }

    private func request(_ permission: AppPermission) async {
        working = permission
        defer { working = nil }
        switch permission {
        case .notifications:
            let granted = await container.notifications.requestAuthorization()
            message = granted ? "已获得通知授权" : "没有拿到通知授权，可在系统设置里开启"
        case .microphone:
            _ = await Self.requestMicrophone()
        case .speechRecognition:
            _ = await Self.requestSpeech()
        }
        await refresh()
    }

    // MARK: - 系统状态映射

    private static func notificationStatus(_ status: UNAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .provisional, .ephemeral: return .limited
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .restricted
        }
    }

    private static func microphoneStatus() -> PermissionStatus {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .notDetermined
        @unknown default: return .restricted
        }
    }

    private static func speechStatus() -> PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .restricted
        }
    }

    private static func requestMicrophone() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        }
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private static func requestSpeech() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

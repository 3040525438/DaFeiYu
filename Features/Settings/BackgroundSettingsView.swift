import SwiftUI
import DFCore

/// D21：后台任务与运行方式说明；D58：离线能力边界说明。
///
/// 只做说明，不提供"保证准点"之类的开关；
/// 后台文案来自 `BackgroundExecutionPolicy.disclosure`，避免各处漂移。
@MainActor
struct BackgroundSettingsView: View {
    /// D58：离线仍可用的本地能力（与实现边界一致，不夸大）
    private static let offlineAvailable = [
        "本地聊天记录（查看历史消息与会话）",
        "记忆浏览与搜索",
        "日记浏览与补写触发",
        "表情与附件的本地读取",
        "设置"
    ]

    /// D58：必须联网且已配置云端模型才能使用的能力
    private static let offlineUnavailable = [
        "云端模型回复",
        "云端图片理解",
        "云端语音转写",
        "在线表情下载"
    ]

    var body: some View {
        List {
            offlineSection

            Section {
                Text(BackgroundExecutionPolicy.disclosure.timing)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("时间")
            }

            Section {
                ForEach(BackgroundExecutionPolicy.disclosure.whatRuns, id: \.self) { item in
                    Text(item)
                        .font(.footnote)
                }
            } header: {
                Text("后台会做什么")
            }

            Section {
                Text(BackgroundExecutionPolicy.disclosure.cost)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("成本")
            }

            Section {
                Text(BackgroundExecutionPolicy.disclosure.privacy)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("隐私")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("后台与运行方式")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// D58：离线能力清单，说明断网时哪些功能仍可用、哪些必须联网。
    private var offlineSection: some View {
        Section {
            ForEach(Self.offlineAvailable, id: \.self) { item in
                capabilityRow(item, available: true)
            }

            Text("以下能力离线时不可用")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.inkMuted)
                .padding(.top, DFSpacing.xs)

            ForEach(Self.offlineUnavailable, id: \.self) { item in
                capabilityRow(item, available: false)
            }
        } header: {
            Text("当前离线可用能力")
        } footer: {
            Text("这些能力需要网络与已配置的云端模型；离线时不会伪造回复。")
                .font(DFFont.caption)
        }
    }

    private func capabilityRow(_ title: String, available: Bool) -> some View {
        HStack(spacing: DFSpacing.s) {
            Image(systemName: available ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(available ? DFColor.success : DFColor.inkMuted)
            Text(title)
                .font(DFFont.body)
                .foregroundStyle(available ? DFColor.ink : DFColor.inkMuted)
        }
    }
}

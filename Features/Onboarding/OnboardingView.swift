import SwiftUI
import DFCore

/// 首启向导（D64）：可跳过非必要步骤，隐私授权单独一页。
@MainActor
struct OnboardingView: View {
    @EnvironmentObject private var container: AppContainer
    let onFinish: () -> Void

    @State private var step = 0
    @State private var cloudGranted = false
    @State private var importGranted = false
    @State private var diagnosticsGranted = false
    @State private var isSaving = false

    private let totalSteps = 4

    var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: Double(step + 1), total: Double(totalSteps))
                .tint(DFColor.primary)
                .padding(.horizontal, 28)
                .padding(.top, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch step {
                    case 0: welcomePage
                    case 1: privacyPage
                    case 2: modelPage
                    default: finishPage
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                if step > 0 {
                    Button("上一步") { step -= 1 }
                        .buttonStyle(.bordered)
                }
                Spacer()
                if step < totalSteps - 1 {
                    Button("跳过非必要步骤") { step = totalSteps - 1 }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button(step == totalSteps - 1 ? "开始使用" : "下一步") {
                    if step == totalSteps - 1 {
                        Task { await finish() }
                    } else {
                        step += 1
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(DFColor.primary)
                .disabled(isSaving)
            }
            .padding(24)
        }
        .background(DFColor.canvas.ignoresSafeArea())
    }

    // MARK: - 页面

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            DFCharacterMark(size: 64)
            Text("欢迎来到大肥鱼")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(DFColor.ink)
            Text("她住在这台设备里：聊天、记忆、日记、人格都保存在本机，不上传第三方。")
                .font(.system(size: 14))
                .foregroundStyle(DFColor.inkMuted)
            VStack(alignment: .leading, spacing: 8) {
                bullet("长期记忆与关系档案，不是一次性问答")
                bullet("可选的云端模型，密钥只存 Keychain")
                bullet("备份默认加密，密钥只在本机")
            }
            .padding(.top, 6)
        }
    }

    private var privacyPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("隐私授权")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(DFColor.ink)
            Text("全部默认关闭，随时可在「设置 → 隐私与安全」修改或撤销。")
                .font(.system(size: 13))
                .foregroundStyle(DFColor.inkMuted)

            consentRow(
                title: PrivacyConsentKind.cloudModel.title,
                detail: PrivacyConsentKind.cloudModel.detail,
                isOn: $cloudGranted
            )
            consentRow(
                title: PrivacyConsentKind.importExport.title,
                detail: PrivacyConsentKind.importExport.detail,
                isOn: $importGranted
            )
            consentRow(
                title: PrivacyConsentKind.diagnosticsExport.title,
                detail: PrivacyConsentKind.diagnosticsExport.detail,
                isOn: $diagnosticsGranted
            )

            Text("语音、图片只在你主动选择时读取，且优先在设备端处理。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var modelPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("模型")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(DFColor.ink)
            Text("聊天需要至少一个 OpenAI 兼容接口，或后续下载本地模型。")
                .font(.system(size: 14))
                .foregroundStyle(DFColor.inkMuted)
            VStack(alignment: .leading, spacing: 8) {
                bullet("接口地址、模型名可随时修改")
                bullet("API Key 只存在系统 Keychain")
                bullet("未配置模型时聊天会明确提示，不会静默失败")
            }
            Text("可以先完成向导，再到「设置 → 模型配置」添加。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var finishPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("准备就绪")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(DFColor.ink)
            Text("建议先做两件事：到设置里配置模型，然后在「备份与恢复」创建第一份加密备份。")
                .font(.system(size: 14))
                .foregroundStyle(DFColor.inkMuted)
            VStack(alignment: .leading, spacing: 8) {
                bullet("聊天里可长按消息编辑、撤回、收藏")
                bullet("人格成长与关系阶段变更都需要你确认")
                bullet("锁屏、Face ID 与删除全部数据都在隐私页")
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(DFColor.primary)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(DFColor.ink)
        }
    }

    private func consentRow(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(DFColor.primary)
    }

    // MARK: - 保存

    private func finish() async {
        isSaving = true
        defer { isSaving = false }
        _ = try? await container.privacy.setConsent(.cloudModel, granted: cloudGranted, note: "首启向导")
        _ = try? await container.privacy.setConsent(.importExport, granted: importGranted, note: "首启向导")
        _ = try? await container.privacy.setConsent(.diagnosticsExport, granted: diagnosticsGranted, note: "首启向导")
        try? await container.settings.set("1", for: "onboarding.completed.v1")
        onFinish()
    }
}

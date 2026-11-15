import SwiftUI
import DFData
import DFCore
import DFAI

/// 语音输入（D28 / D16）：录制 → 按当前运行方式转写 → 可回放 → 填入聊天框。
/// 原始音频保存在附件库，转写文本落 `attachment_texts`；
/// 填入时把附件 id 一并交给调用方，发送后由聊天页挂到该条消息上。
///
/// 运行方式（D16）：
/// - 设备端：音频不出设备，默认方式；
/// - 云端：必须先在隐私授权里显式同意上传，未授权或拒绝一律不开始，并给文字兜底。
@MainActor
struct VoiceInputSheet: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    /// 参数：转写文本、录音附件 id（无录音时为 nil）
    let onInsert: (String, String?) -> Void

    @StateObject private var recorder = VoiceRecorder()
    @StateObject private var player = AudioPreviewPlayer()
    @State private var attachmentURL: URL?
    /// D28：已入库的录音附件，发送时挂到用户消息上
    @State private var ingestedAttachmentID: String?
    @State private var transcript = ""
    @State private var busy = false
    @State private var message: String?

    /// D16：运行方式与本次输入的处理方案
    @State private var mode: SpeechRunMode = .onDevice
    @State private var consent: SpeechUploadConsent = .undetermined
    @State private var plan: SpeechInputPlan?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                modeSection
                levelMeter
                Text(timeText(recorder.elapsed))
                    .font(.system(size: 30, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(DFColor.ink)

                Button {
                    Task { await toggleRecording() }
                } label: {
                    Image(systemName: recorder.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 62))
                        .foregroundStyle(recorder.isRecording ? .red : DFColor.primary)
                }
                .disabled(busy)

                Text(recorder.isRecording ? "正在录音…" : "点击开始录音")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let attachmentURL {
                    playbackRow(url: attachmentURL)
                }

                if !transcript.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("转写结果")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $transcript)
                            .font(.system(size: 14))
                            .frame(minHeight: 90)
                            .padding(8)
                            .background(DFColor.surfaceAlt, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }

                if busy {
                    ProgressView(plan?.mode == .cloud ? "正在云端转写…" : "正在本机转写…")
                }
                if let plan {
                    if SpeechInputPolicy.needsConsentPrompt(plan) {
                        Button("允许上传音频并识别") {
                            Task { await grantUploadConsent() }
                        }
                        .font(.footnote)
                        .buttonStyle(.borderedProminent)
                        .tint(DFColor.primary)
                    }
                    Text(plan.explanation)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    if let alternative = plan.alternative {
                        Text(alternative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                }
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Spacer()
            }
            .padding(20)
            .background(DFColor.canvas.ignoresSafeArea())
            .task { await refreshPlan() }
            .navigationTitle("语音输入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        recorder.cancel()
                        player.stop()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("填入") {
                        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        onInsert(text, ingestedAttachmentID)
                        dismiss()
                    }
                    .disabled(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    /// D16：运行方式切换（切换即落库，下次打开沿用）
    private var modeSection: some View {
        Picker("转写方式", selection: Binding(
            get: { mode },
            set: { value in Task { await selectMode(value) } }
        )) {
            ForEach(SpeechRunMode.selectable, id: \.self) { item in
                Text(item.displayName).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .disabled(busy || recorder.isRecording)
    }

    private var levelMeter: some View {
        HStack(spacing: 4) {
            ForEach(0..<12, id: \.self) { index in
                Capsule()
                    .fill(DFColor.primary.opacity(recorder.isRecording ? 1 : 0.25))
                    .frame(width: 6, height: CGFloat(8 + index * 2))
                    .opacity(recorder.isRecording && Double(index) / 12.0 <= recorder.level ? 1 : 0.3)
            }
        }
        .frame(height: 34, alignment: .center)
    }

    private func playbackRow(url: URL) -> some View {
        HStack(spacing: 12) {
            Button {
                player.toggle(url: url)
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(DFColor.primary)
            }
            ProgressView(value: player.progress)
                .tint(DFColor.primary)
        }
        .padding(12)
        .background(DFColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func toggleRecording() async {
        if recorder.isRecording {
            guard let url = recorder.stop() else {
                message = "录音太短，已忽略"
                return
            }
            attachmentURL = url
            player.load(url: url)
            await transcribe(url: url)
        } else {
            message = nil
            transcript = ""
            ingestedAttachmentID = nil
            player.stop()
            do {
                try await recorder.start()
            } catch {
                message = String(describing: error)
            }
        }
    }

    private func transcribe(url: URL) async {
        guard let plan else {
            message = "转写方式尚未就绪，请稍后重试"
            return
        }
        guard plan.allowed else {
            message = plan.explanation
            return
        }

        busy = true
        defer { busy = false }
        do {
            let data = try Data(contentsOf: url)
            let timestamp = Clock.nowMillis()
            let record = try await container.media.ingest(
                data: data,
                fileExtension: "m4a",
                messageID: nil,
                at: timestamp
            )
            ingestedAttachmentID = record.id

            switch plan.mode {
            case .onDevice:
                let result = try await container.media.runTranscription(attachment: record, at: timestamp)
                transcript = result?.text ?? ""
            case .cloud:
                transcript = try await transcribeOnCloud(data: data, record: record)
            case .unavailable:
                transcript = ""
            }

            if transcript.isEmpty {
                message = "没有识别到语音内容"
            }
        } catch {
            message = "转写失败：\(error.localizedDescription)"
        }
    }

    /// D16：云端转写。只有 `plan.allowed == true`（已显式授权）时才会走到这里。
    private func transcribeOnCloud(data: Data, record: AttachmentRecord) async throws -> String {
        guard let config = try await container.modelConfigs.defaultConfig() else {
            throw DFError.notConfigured("默认模型（请到设置页添加）")
        }
        guard let baseURL = URL(string: config.baseURL), baseURL.scheme?.hasPrefix("http") == true else {
            throw DFError.invalidURL(config.baseURL)
        }
        let configuredModel = (try? await container.settings.string(for: SpeechSettingsKey.cloudModel))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (configuredModel?.isEmpty == false ? configuredModel : nil)
            ?? SpeechTranscriptionWire.defaultModel

        let transcriber = CloudSpeechTranscriber(
            baseURL: baseURL,
            apiKey: try container.apiKey(for: config),
            model: model
        )
        let text = try await transcriber.transcribe(
            audio: data,
            fileName: (record.relPath as NSString).lastPathComponent
        )
        try await container.media.saveCloudTranscript(
            attachment: record,
            text: text,
            model: model,
            at: Clock.nowMillis()
        )
        return text
    }

    // MARK: - D16 运行方式与授权

    private func refreshPlan() async {
        mode = SpeechRunMode(settingValue: try? await container.settings.string(for: SpeechSettingsKey.mode))
        let all = (try? await container.privacy.consents()) ?? []
        if let record = all.first(where: { $0.kind == .speechRecognition }) {
            consent = record.granted ? .granted : .denied
        } else {
            consent = .undetermined
        }
        rebuildPlan()
    }

    private func selectMode(_ value: SpeechRunMode) async {
        mode = value
        try? await container.settings.set(value.rawValue, for: SpeechSettingsKey.mode)
        rebuildPlan()
    }

    private func grantUploadConsent() async {
        do {
            _ = try await container.privacy.setConsent(
                .speechRecognition,
                granted: true,
                note: "语音输入：允许把录音上传到当前模型服务商转写"
            )
            consent = .granted
            rebuildPlan()
        } catch {
            message = "授权记录失败：\(error.localizedDescription)"
        }
    }

    private func rebuildPlan() {
        plan = SpeechInputPolicy.plan(
            preferred: mode,
            deviceOnDeviceAvailable: MediaProcessing.onDeviceSpeechAvailable(),
            consent: consent
        )
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

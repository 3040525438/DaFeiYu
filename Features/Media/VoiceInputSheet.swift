import SwiftUI
import DFData
import DFCore

/// 语音输入（D28）：录制 → 设备端转写 → 可回放 → 填入聊天框。
/// 原始音频保存在附件库，转写文本落 `attachment_texts`。
@MainActor
struct VoiceInputSheet: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    let onInsert: (String) -> Void

    @StateObject private var recorder = VoiceRecorder()
    @StateObject private var player = AudioPreviewPlayer()
    @State private var attachmentURL: URL?
    @State private var transcript = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
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
                    ProgressView("正在本机转写…")
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
                        onInsert(text)
                        dismiss()
                    }
                    .disabled(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
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
            player.stop()
            do {
                try await recorder.start()
            } catch {
                message = String(describing: error)
            }
        }
    }

    private func transcribe(url: URL) async {
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
            let result = try await container.media.runTranscription(attachment: record, at: timestamp)
            transcript = result?.text ?? ""
            if transcript.isEmpty {
                message = "没有识别到语音内容"
            }
        } catch {
            message = "转写失败：\(error.localizedDescription)"
        }
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

import Foundation
import AVFoundation

/// 语音录制（D28）：只落本地临时文件，转写由设备端完成，不自动上传。
@MainActor
final class VoiceRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Double = 0
    @Published private(set) var permissionDenied = false

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?
    private(set) var fileURL: URL?

    func requestPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            let granted = await AVAudioApplication.requestRecordPermission()
            permissionDenied = !granted
            return granted
        } else {
            let granted = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { ok in
                    continuation.resume(returning: ok)
                }
            }
            permissionDenied = !granted
            return granted
        }
    }

    func start() async throws {
        guard await requestPermission() else {
            throw VoiceError.permissionDenied
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw VoiceError.recorderUnavailable
        }
        self.recorder = recorder
        self.fileURL = url
        self.startedAt = Date()
        self.isRecording = true
        self.elapsed = 0
        startTicking()
    }

    /// 停止并返回录音文件；太短（<0.6s）视为误触，返回 nil 并自动清理。
    func stop() -> URL? {
        guard let recorder, let url = fileURL else { return nil }
        recorder.stop()
        stopTicking()
        isRecording = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let duration = elapsed
        self.recorder = nil
        if duration < 0.6 {
            try? FileManager.default.removeItem(at: url)
            fileURL = nil
            elapsed = 0
            return nil
        }
        return url
    }

    func cancel() {
        recorder?.stop()
        stopTicking()
        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        fileURL = nil
        recorder = nil
        isRecording = false
        level = 0
        elapsed = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startTicking() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let recorder, let startedAt else { return }
        recorder.updateMeters()
        elapsed = Date().timeIntervalSince(startedAt)
        // -60dB…0dB → 0…1
        let power = Double(recorder.averagePower(forChannel: 0))
        level = max(0, min(1, (power + 60) / 60))
    }
}

enum VoiceError: Error, CustomStringConvertible {
    case permissionDenied
    case recorderUnavailable

    var description: String {
        switch self {
        case .permissionDenied: return "没有麦克风权限，请到系统设置里开启"
        case .recorderUnavailable: return "录音器启动失败"
        }
    }
}

/// 录音回放：播放/暂停/停止，并提供进度。
@MainActor
final class AudioPreviewPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(url: URL) {
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.delegate = self
        player.prepareToPlay()
        self.player = player
        self.duration = player.duration
        self.progress = 0
    }

    func toggle(url: URL) {
        if let player, player.isPlaying {
            pause()
        } else if player != nil {
            resume()
        } else {
            load(url: url)
            play()
        }
    }

    func play() {
        guard let player else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            return
        }
        player.play()
        isPlaying = true
        startTicking()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicking()
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        progress = 0
        duration = 0
        stopTicking()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.progress = 0
            self.stopTicking()
        }
    }

    private func startTicking() {
        stopTicking()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.progress = player.duration > 0 ? player.currentTime / player.duration : 0
            }
        }
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }
}

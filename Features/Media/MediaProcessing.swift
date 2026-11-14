import Foundation
import UIKit
import ImageIO
import Vision
import Speech
import AVFoundation
import UniformTypeIdentifiers

/// 媒体基础能力：类型识别、尺寸/时长、缩略图、设备端 OCR 与语音转写。
///
/// 约束（D16 / D17 / D27 / D28）：
/// - OCR 与语音识别优先使用设备端能力，不把原始媒体上传第三方；
/// - 只产出派生文本与缩略图，原始文件由 `AttachmentStore` 内容寻址保存，永不改写；
/// - 所有能力失败都抛错，不做"空字符串冒充识别成功"。
enum MediaProcessing {
    // MARK: - 类型

    struct KindInfo: Equatable {
        var kind: String
        var mime: String
        var fileExtension: String
    }

    /// 按扩展名判定附件类别。无法识别时回落 `file` + `application/octet-stream`。
    static func kindInfo(forExtension ext: String) -> KindInfo {
        let lowered = ext.lowercased()
        guard !lowered.isEmpty, let type = UTType(filenameExtension: lowered) else {
            return KindInfo(kind: "file", mime: "application/octet-stream", fileExtension: lowered)
        }
        let kind: String
        if type.conforms(to: .image) {
            kind = "image"
        } else if type.conforms(to: .audio) {
            kind = "audio"
        } else if type.conforms(to: .movie) || type.conforms(to: .video) {
            kind = "video"
        } else if type.conforms(to: .text) || type.conforms(to: .pdf) {
            kind = "document"
        } else {
            kind = "file"
        }
        return KindInfo(
            kind: kind,
            mime: type.preferredMIMEType ?? "application/octet-stream",
            fileExtension: lowered
        )
    }

    // MARK: - 图片

    /// 读取像素尺寸（不是 point 尺寸）。失败返回 nil，不猜测。
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }
        return (width, height)
    }

    /// 生成最长边 512 的 JPEG 缩略图；无法解码返回 nil。
    static func thumbnailJPEG(of data: Data, maxPixel: Int = 512) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.8)
    }

    // MARK: - 音频 / 视频

    /// 读取媒体时长（毫秒）；无法读取返回 nil。
    static func durationMillis(ofFileAt url: URL) async -> Int? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds >= 0 else { return nil }
            return Int((seconds * 1000).rounded())
        } catch {
            return nil
        }
    }

    // MARK: - OCR（设备端）

    struct OCRResult: Equatable {
        var text: String
        /// 各文本块置信度的均值；无结果时为 nil
        var confidence: Double?
        var languages: [String]
    }

    enum MediaError: Error, CustomStringConvertible {
        case imageDecodeFailed
        case ocrFailed(String)
        case speechUnavailable
        case speechFailed(String)

        var description: String {
            switch self {
            case .imageDecodeFailed: return "图片无法解码"
            case .ocrFailed(let reason): return "文字识别失败：\(reason)"
            case .speechUnavailable: return "当前设备不支持语音识别"
            case .speechFailed(let reason): return "语音转写失败：\(reason)"
            }
        }
    }

    /// 设备端 OCR：中文优先，英文兜底。不联网、不上传。
    static func recognizeText(in data: Data) async throws -> OCRResult {
        guard let image = UIImage(data: data), let cgImage = image.cgImage else {
            throw MediaError.imageDecodeFailed
        }

        let languages = ["zh-Hans", "zh-Hant", "en-US"]
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: MediaError.ocrFailed(error.localizedDescription))
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first }
                let text = lines.map(\.string).joined(separator: "\n")
                let confidences = lines.map { Double($0.confidence) }
                let average = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
                let usedLanguages = (request as? VNRecognizeTextRequest)?.recognitionLanguages ?? languages
                continuation.resume(returning: OCRResult(
                    text: text,
                    confidence: average,
                    languages: usedLanguages
                ))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = languages

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: MediaError.ocrFailed(error.localizedDescription))
            }
        }
    }

    // MARK: - 语音转写（设备端优先）

    /// 设备端转写。若设备不支持端上识别，则显式抛错，绝不静默改为云端上传。
    static func transcribe(fileURL: URL, localeIdentifier: String = "zh-CN") async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable else {
            throw MediaError.speechUnavailable
        }
        let supportsOnDevice = recognizer.supportsOnDeviceRecognition
        guard supportsOnDevice else {
            throw MediaError.speechUnavailable
        }

        let authorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard authorized else {
            throw MediaError.speechUnavailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: fileURL)
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = false

            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let error {
                    finished = true
                    continuation.resume(throwing: MediaError.speechFailed(error.localizedDescription))
                    return
                }
                guard let result, result.isFinal else { return }
                finished = true
                continuation.resume(returning: result.bestTranscription.formattedString)
            }
        }
    }
}

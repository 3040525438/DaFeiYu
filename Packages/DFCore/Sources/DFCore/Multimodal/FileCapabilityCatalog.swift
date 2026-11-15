import Foundation

// MARK: - 常见文件类型的能力分级（D29）
//
// 目标：明确每种附件"能保存 / 能预览 / 能读文字 / 能被模型理解"分别到什么程度，
// 界面与提示词都以此为唯一口径，避免把"能存下来"说成"能读懂"。
//
// 只做纯判断，不依赖 UIKit / QuickLook，便于在 CI 覆盖全部类型。

/// 单种能力
public enum FileCapability: String, Sendable, Equatable, CaseIterable {
    /// 可以保存到附件库
    case save
    /// 可以在 App 内预览（图片查看 / 播放 / 文本查看 / 系统 QuickLook）
    case preview
    /// 可以提取出可检索的文字（OCR / 语音转写 / 纯文本）
    case readText = "read_text"
    /// 可以作为上下文交给模型理解
    case understand

    public var displayName: String {
        switch self {
        case .save: return "保存"
        case .preview: return "预览"
        case .readText: return "读取文字"
        case .understand: return "模型理解"
        }
    }
}

/// 一类文件的完整能力说明
public struct FileCapabilityProfile: Sendable, Equatable {
    /// 归一化后的类别：image / audio / video / text / pdf / archive / other
    public var category: String
    public var capabilities: Set<FileCapability>
    /// 给用户看的一句话说明（如实描述限制）
    public var note: String

    public init(category: String, capabilities: Set<FileCapability>, note: String) {
        self.category = category
        self.capabilities = capabilities
        self.note = note
    }

    public func supports(_ capability: FileCapability) -> Bool {
        capabilities.contains(capability)
    }
}

public enum FileCapabilityCatalog {
    /// 图片：可保存、可预览、可 OCR 出文字；云端/本地视觉通道可按配置理解
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp"]
    /// 音频：可保存、可播放、可转写
    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aac", "caf", "flac"]
    /// 视频：可保存、可播放；当前不做抽帧，因而不读取文字、不交给模型
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    /// 纯文本：可保存、可预览、可直接读取并注入上下文
    static let textExtensions: Set<String> = ["txt", "md", "markdown", "json", "csv", "log"]

    /// 按文件名（优先扩展名）与 MIME 判断能力。
    public static func profile(fileName: String, mime: String = "") -> FileCapabilityProfile {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let normalizedMime = mime.lowercased()

        if imageExtensions.contains(ext) || normalizedMime.hasPrefix("image/") {
            return FileCapabilityProfile(
                category: "image",
                capabilities: [.save, .preview, .readText, .understand],
                note: "可保存、查看原图并识别文字；是否交给模型理解取决于当前运行模式"
            )
        }
        if audioExtensions.contains(ext) || normalizedMime.hasPrefix("audio/") {
            return FileCapabilityProfile(
                category: "audio",
                capabilities: [.save, .preview, .readText],
                note: "可保存、播放并转写为文字；转写需要语音识别可用"
            )
        }
        if videoExtensions.contains(ext) || normalizedMime.hasPrefix("video/") {
            return FileCapabilityProfile(
                category: "video",
                capabilities: [.save, .preview],
                note: "可保存与播放；当前不抽帧，因此不读取视频内容"
            )
        }
        if textExtensions.contains(ext) || normalizedMime.hasPrefix("text/")
            || normalizedMime == "application/json" || normalizedMime == "text/csv" {
            return FileCapabilityProfile(
                category: "text",
                capabilities: [.save, .preview, .readText, .understand],
                note: "可直接查看并把文字内容作为上下文"
            )
        }
        if ext == "pdf" || normalizedMime == "application/pdf" {
            return FileCapabilityProfile(
                category: "pdf",
                capabilities: [.save, .preview],
                note: "可保存与预览；当前不提取 PDF 正文，因此不能按内容检索或理解"
            )
        }
        if ["zip", "rar", "7z", "tar", "gz"].contains(ext) {
            return FileCapabilityProfile(
                category: "archive",
                capabilities: [.save],
                note: "仅保存原文件；不支持解压、预览或读取"
            )
        }
        return FileCapabilityProfile(
            category: "other",
            capabilities: [.save],
            note: "仅保存原文件；暂不支持预览、读取或理解"
        )
    }

    /// 能力摘要，用于列表行副标题（如「保存 · 预览 · 读取文字」）。
    public static func summary(_ profile: FileCapabilityProfile) -> String {
        FileCapability.allCases
            .filter { profile.supports($0) }
            .map(\.displayName)
            .joined(separator: " · ")
    }
}

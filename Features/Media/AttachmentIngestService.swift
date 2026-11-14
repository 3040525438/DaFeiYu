import Foundation
import DFCore

/// 附件入库与派生处理（W4）。
///
/// 顺序固定为「先落文件 → 再写库 → 再补派生指标」：
/// 任一步失败都不会出现"库里有记录、磁盘没文件"或"缩略图指向不存在的路径"。
struct AttachmentIngestService: Sendable {
    let store: AttachmentStore
    let repository: AttachmentRepository
    let textRepository: AttachmentTextRepository

    /// 入库一个文件并可选地挂到消息上。
    @discardableResult
    func ingest(
        data: Data,
        fileExtension: String,
        messageID: String?,
        sort: Int = 0,
        at millis: Int64
    ) async throws -> AttachmentRecord {
        let info = MediaProcessing.kindInfo(forExtension: fileExtension)
        let stored = try store.store(data: data, fileExtension: info.fileExtension)
        let record = try await repository.ensure(NewAttachment(
            sha256: stored.sha256,
            kind: info.kind,
            relPath: stored.relativePath,
            byteSize: stored.byteSize,
            mime: info.mime,
            createdAt: millis
        ))

        switch info.kind {
        case "image":
            let size = MediaProcessing.pixelSize(of: data)
            var thumbnailPath: String?
            if let thumbnail = MediaProcessing.thumbnailJPEG(of: data) {
                // 缩略图也走内容寻址：同一张图重复入库不会产生多份副本
                thumbnailPath = try? store.store(data: thumbnail, fileExtension: "jpg").relativePath
            }
            try await repository.setMetrics(
                id: record.id,
                width: size?.width,
                height: size?.height,
                durationMs: nil,
                thumbnailRelPath: thumbnailPath
            )
        case "audio", "video":
            let url = store.fileURL(forRelativePath: stored.relativePath)
            if let duration = await MediaProcessing.durationMillis(ofFileAt: url) {
                try await repository.setMetrics(
                    id: record.id,
                    width: nil,
                    height: nil,
                    durationMs: duration,
                    thumbnailRelPath: nil
                )
            }
        default:
            break
        }

        if let messageID {
            try await repository.link(messageID: messageID, attachmentID: record.id, sort: sort)
        }
        return try await repository.attachment(id: record.id) ?? record
    }

    /// 对图片执行设备端 OCR 并落库。空文本视为"没有识别到文字"，不写记录。
    @discardableResult
    func runOCR(attachment record: AttachmentRecord, at millis: Int64) async throws -> AttachmentTextRecord? {
        guard record.kind == "image" else { return nil }
        guard let data = try? Data(contentsOf: store.fileURL(forRelativePath: record.relPath)) else {
            throw MediaProcessing.MediaError.imageDecodeFailed
        }
        let result = try await MediaProcessing.recognizeText(in: data)
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try await textRepository.upsert(
            attachmentID: record.id,
            kind: .ocr,
            text: result.text,
            language: result.languages.first,
            engine: "vision-on-device",
            confidence: result.confidence,
            at: millis
        )
    }

    /// 对音频执行设备端转写并落库。设备不支持端上识别时抛错，不偷偷上传。
    @discardableResult
    func runTranscription(
        attachment record: AttachmentRecord,
        at millis: Int64,
        localeIdentifier: String = "zh-CN"
    ) async throws -> AttachmentTextRecord? {
        guard record.kind == "audio" || record.kind == "video" else { return nil }
        let url = store.fileURL(forRelativePath: record.relPath)
        let text = try await MediaProcessing.transcribe(fileURL: url, localeIdentifier: localeIdentifier)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try await textRepository.upsert(
            attachmentID: record.id,
            kind: .transcript,
            text: trimmed,
            language: localeIdentifier,
            engine: "speech-on-device",
            confidence: nil,
            at: millis
        )
    }
}

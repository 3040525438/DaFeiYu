import SwiftUI
import PhotosUI
import UIKit
import DFData
import DFCore
import DFAI

/// 图片理解调用链（D05 / D17 / D71）：
/// 选图 → 入库（缩略图/尺寸）→ 设备端 OCR → 需要时调用视觉模型 → 结果落 `image_analyses` → 可填入聊天框。
@MainActor
struct ImageUnderstandingSheet: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    let onInsert: (String) -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var imageData: Data?
    @State private var attachmentID: String?
    @State private var ocrText = ""
    @State private var caption = ""
    @State private var description = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label(image == nil ? "选择图片" : "换一张图片", systemImage: "photo.on.rectangle")
                            .font(.system(size: 14, weight: .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(DFColor.primarySoft, in: Capsule())
                            .foregroundStyle(DFColor.primary)
                    }
                    .onChange(of: pickerItem) { _, item in
                        Task { await load(item) }
                    }

                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    if !ocrText.isEmpty {
                        section(title: "设备端识别到的文字") {
                            Text(ocrText)
                                .font(.system(size: 13))
                                .foregroundStyle(DFColor.ink)
                        }
                    }

                    section(title: "想问什么（可留空）") {
                        TextField("比如：这张图里有什么值得注意的？", text: $caption, axis: .vertical)
                            .lineLimit(2...4)
                            .textFieldStyle(.plain)
                    }

                    if attachmentID != nil {
                        Button {
                            Task { await analyze() }
                        } label: {
                            Label(busy ? "正在理解…" : "让大肥鱼看图", systemImage: "sparkles")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(DFColor.primary)
                        .disabled(busy)
                    }

                    if !description.isEmpty {
                        section(title: "图片理解结果") {
                            Text(description)
                                .font(.system(size: 13))
                                .foregroundStyle(DFColor.ink)
                        }
                    }

                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding(18)
            }
            .background(DFColor.canvas.ignoresSafeArea())
            .navigationTitle("图片理解")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("填入") {
                        let text = insertText
                        guard !text.isEmpty else { return }
                        onInsert(text)
                        dismiss()
                    }
                    .disabled(insertText.isEmpty)
                }
            }
        }
    }

    private var insertText: String {
        if !description.isEmpty { return description }
        if !ocrText.isEmpty { return "【图片文字】\n\(ocrText)" }
        return ""
    }

    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DFColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func load(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        busy = true
        defer { busy = false }
        message = nil
        description = ""
        ocrText = ""
        attachmentID = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let original = UIImage(data: data) else {
                message = "无法读取这张图片"
                return
            }
            // 统一转 JPEG：保证入库格式、OCR 与 data URL 的 MIME 一致
            guard let jpeg = original.jpegData(compressionQuality: 0.86) else {
                message = "图片编码失败"
                return
            }
            image = original
            imageData = jpeg
            let timestamp = Clock.nowMillis()
            let record = try await container.media.ingest(
                data: jpeg,
                fileExtension: "jpg",
                messageID: nil,
                at: timestamp
            )
            attachmentID = record.id
            let text = try await container.media.runOCR(attachment: record, at: timestamp)
            ocrText = text?.text ?? ""
            if ocrText.isEmpty {
                message = "没有识别到文字；仍可以让模型看图。"
            }
        } catch {
            message = "处理失败：\(error.localizedDescription)"
        }
    }

    private func analyze() async {
        guard let attachmentID, let imageData else { return }
        if !(try await container.privacy.isGranted(.cloudModel)) {
            message = "当前未授权云端模型。请到「设置 → 隐私与安全 → 授权记录」开启，或稍后用本地模型。"
            return
        }
        busy = true
        defer { busy = false }
        message = nil

        do {
            let config = try await container.modelConfigs.defaultConfig().unwrap(or: DFError.notConfigured("默认模型（请到设置页添加）"))
            let timestamp = Clock.nowMillis()
            let prompt = caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "请描述这张图片的内容，并指出值得注意的细节。"
                : caption
            let analysis = try await container.imageAnalyses.create(
                conversationID: nil,
                messageID: nil,
                attachmentIDs: [attachmentID],
                prompt: prompt,
                modelConfigID: config.id,
                at: timestamp
            )

            let provider = try container.provider(for: config)
            let request = ChatRequest(
                model: config.modelID,
                systemPrompt: "你在帮用户理解图片。用简体中文回答，先给结论再给细节，不要编造看不见的内容。",
                messages: [
                    ChatTurn(
                        role: .user,
                        text: prompt,
                        images: [ChatImage(mimeType: "image/jpeg", base64: imageData.base64EncodedString())]
                    )
                ],
                temperature: 0.4,
                maxTokens: 600
            )
            var text = ""
            for try await delta in provider.stream(request) {
                if case .text(let chunk) = delta {
                    text += chunk
                }
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                try? await container.imageAnalyses.finish(id: analysis.id, result: "", status: "failed", at: Clock.nowMillis())
                message = "模型没有返回内容"
                return
            }
            try await container.imageAnalyses.finish(
                id: analysis.id,
                result: trimmed,
                status: "done",
                at: Clock.nowMillis()
            )
            description = trimmed
        } catch {
            message = "图片理解失败：\(error.localizedDescription)"
        }
    }
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> Error) throws -> Wrapped {
        guard let value = self else { throw error() }
        return value
    }
}

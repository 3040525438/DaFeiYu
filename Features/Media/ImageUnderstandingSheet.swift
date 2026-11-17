import SwiftUI
import PhotosUI
import UIKit
import DFData
import DFCore
import DFAI

/// 图片理解调用链（D05 / D17 / D71）：
/// 选图（可多选）→ 逐张入库（缩略图/尺寸）→ 设备端 OCR → 需要时逐张调用视觉模型
/// → 结果落 `image_analyses` → 按图片分组展示 → 汇总后填入聊天框。
/// 每张图独立分析：单张失败只标记该图，不影响其他图。
@MainActor
struct ImageUnderstandingSheet: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    let onInsert: (String) -> Void

    /// 一次最多可选张数，避免逐张请求过多
    private static let maxSelectionCount = 8

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var entries: [ImageUnderstandingEntry] = []
    @State private var caption = ""
    /// 汇总文本：所有成功结果合并后仍可编辑
    @State private var summary = ""
    @State private var busy = false
    /// 逐张进度文案（读取 / 分析）
    @State private var busyText = ""
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DFSpacing.m) {
                    picker

                    if entries.isEmpty {
                        emptyState
                    } else {
                        ForEach(entries.indices, id: \.self) { index in
                            entryCard(index: index, entry: entries[index])
                        }
                    }

                    if entries.count == 1, !entries[0].ocrText.isEmpty {
                        section(title: "设备端识别到的文字") {
                            Text(entries[0].ocrText)
                                .font(.system(size: 13))
                                .foregroundStyle(DFColor.ink)
                        }
                    }

                    if entries.count == 1, entries[0].attachmentID != nil, entries[0].ocrText.isEmpty {
                        Text("没有识别到文字；仍可以让模型看图。")
                            .font(DFFont.caption)
                            .foregroundStyle(DFColor.inkMuted)
                    }

                    questionSection

                    if hasAnalyzableEntry {
                        Button {
                            Task { await analyzeAll() }
                        } label: {
                            Label(busy ? "正在理解…" : analyzeButtonTitle, systemImage: "sparkles")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(DFColor.primary)
                        .disabled(busy)
                    }

                    if busy {
                        HStack(spacing: DFSpacing.s) {
                            ProgressView()
                            Text(busyText)
                                .font(DFFont.caption)
                                .foregroundStyle(DFColor.inkMuted)
                        }
                    }

                    // 单张时结论已在图卡内展示，不再重复一段汇总
                    if entries.count > 1, failureCount > 0 {
                        Text("\(failureCount) 张图片失败，已从汇总中跳过。")
                            .font(DFFont.caption)
                            .foregroundStyle(DFColor.warning)
                    }

                    if entries.count > 1, !summary.isEmpty {
                        section(title: "汇总结果（可编辑）") {
                            TextEditor(text: $summary)
                                .font(.system(size: 13))
                                .frame(minHeight: 120)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .background(
                                    DFColor.surfaceAlt,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                        }
                    }

                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(DFColor.danger)
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

    // MARK: - 子视图

    private var picker: some View {
        PhotosPicker(
            selection: $pickerItems,
            maxSelectionCount: Self.maxSelectionCount,
            matching: .images
        ) {
            Label(
                entries.isEmpty ? "选择图片" : "重新选择图片",
                systemImage: "photo.on.rectangle"
            )
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(DFColor.primarySoft, in: Capsule())
            .foregroundStyle(DFColor.primary)
        }
        .onChange(of: pickerItems) { _, picked in
            Task { await load(picked) }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DFSpacing.xs) {
            Text("还没有选择图片")
                .font(DFFont.body)
                .foregroundStyle(DFColor.ink)
            Text("可一次选择多张，逐张分析后汇总成一段文字。")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.inkMuted)
        }
        .padding(DFSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DFColor.surface, in: RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous))
    }

    private var questionSection: some View {
        section(title: "想问什么（可留空）") {
            TextField(
                entries.count > 1
                    ? "比如：这几张图里分别有什么值得注意的？"
                    : "比如：这张图里有什么值得注意的？",
                text: $caption,
                axis: .vertical
            )
            .lineLimit(2...4)
            .textFieldStyle(.plain)
        }
    }

    private func entryCard(index: Int, entry: ImageUnderstandingEntry) -> some View {
        VStack(alignment: .leading, spacing: DFSpacing.s) {
            HStack(spacing: DFSpacing.s) {
                thumbnail(entry.image)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entries.count > 1 ? "第 \(index + 1) 张" : "图片")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.inkMuted)
                    Text(statusText(for: entry))
                        .font(DFFont.caption)
                        .foregroundStyle(statusColor(for: entry))
                }
                Spacer(minLength: 0)
            }

            if !entry.result.isEmpty {
                Text(entry.result)
                    .font(.system(size: 13))
                    .foregroundStyle(DFColor.ink)
                    .textSelection(.enabled)
            }

            if let errorText = entry.errorText {
                Text(errorText)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.danger)
            }

            if entries.count > 1, !entry.ocrText.isEmpty {
                Text("识别到文字：\(entry.ocrText)")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.inkMuted)
                    .lineLimit(3)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DFColor.surface, in: RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous))
    }

    private func thumbnail(_ image: UIImage?) -> some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    DFColor.surfaceAlt
                    Image(systemName: "photo")
                        .foregroundStyle(DFColor.inkMuted)
                }
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    // MARK: - 状态与文案

    private var hasAnalyzableEntry: Bool {
        entries.contains { $0.attachmentID != nil && $0.jpegData != nil }
    }

    private var failureCount: Int {
        entries.filter { $0.errorText != nil }.count
    }

    private var analyzeButtonTitle: String {
        entries.count > 1 ? "让大肥鱼逐张看图" : "让大肥鱼看图"
    }

    /// 填入聊天框的文本：优先汇总结果；没有模型结果时沿用 OCR 兜底
    private var insertText: String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }

        let ocrTexts = entries
            .map { $0.ocrText.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !ocrTexts.isEmpty else { return "" }
        if ocrTexts.count == 1 {
            return "【图片文字】\n\(ocrTexts[0])"
        }
        return ocrTexts.enumerated()
            .map { "【图片 \($0.offset + 1) 文字】\n\($0.element)" }
            .joined(separator: "\n\n")
    }

    private func statusText(for entry: ImageUnderstandingEntry) -> String {
        if entry.isAnalyzing { return "分析中…" }
        if !entry.result.isEmpty { return "已完成" }
        if entry.errorText != nil { return "失败" }
        if entry.attachmentID != nil { return "待分析" }
        return "未入库"
    }

    private func statusColor(for entry: ImageUnderstandingEntry) -> Color {
        if entry.isAnalyzing { return DFColor.primary }
        if !entry.result.isEmpty { return DFColor.success }
        if entry.errorText != nil { return DFColor.danger }
        return DFColor.inkMuted
    }

    // MARK: - 读取与入库

    /// 逐张读取、入库并跑设备端 OCR；单张失败只记录该图错误
    private func load(_ picked: [PhotosPickerItem]) async {
        guard !picked.isEmpty else { return }
        // 正在读取或分析时忽略重新选择，避免两次流程交叉写同一份列表
        guard !busy else { return }
        busy = true
        message = nil
        summary = ""
        entries = []
        defer {
            busy = false
            busyText = ""
        }

        for (offset, item) in picked.enumerated() {
            busyText = picked.count == 1
                ? "正在读取图片…"
                : "正在处理第 \(offset + 1)/\(picked.count) 张图片…"
            var entry = ImageUnderstandingEntry()
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let original = UIImage(data: data) else {
                    throw ImageUnderstandingLoadError.unreadable
                }
                // 统一转 JPEG：保证入库格式、OCR 与 data URL 的 MIME 一致
                guard let jpeg = original.jpegData(compressionQuality: 0.86) else {
                    throw ImageUnderstandingLoadError.encodeFailed
                }
                entry.image = original
                entry.jpegData = jpeg
                let timestamp = Clock.nowMillis()
                let record = try await container.media.ingest(
                    data: jpeg,
                    fileExtension: "jpg",
                    messageID: nil,
                    at: timestamp
                )
                entry.attachmentID = record.id
                let text = try await container.media.runOCR(attachment: record, at: timestamp)
                entry.ocrText = text?.text ?? ""
            } catch {
                entry.errorText = "处理失败：\(error.localizedDescription)"
            }
            entries.append(entry)
        }
    }

    // MARK: - 逐张分析

    /// 对每张已入库的图片独立走现有单图分析，最后合并成功结果
    private func analyzeAll() async {
        let targets = entries.indices.filter {
            entries[$0].attachmentID != nil && entries[$0].jpegData != nil
        }
        guard !targets.isEmpty else { return }

        do {
            guard try await container.privacy.isGranted(.cloudModel) else {
                message = "当前未授权云端模型。请到「设置 → 隐私与安全 → 授权记录」开启，或稍后用本地模型。"
                return
            }
        } catch {
            message = "授权检查失败：\(error.localizedDescription)"
            return
        }

        let config: ModelConfig
        do {
            config = try await container.modelConfigs
                .defaultConfig()
                .unwrap(or: DFError.notConfigured("默认模型（请到设置页添加）"))
        } catch {
            message = "图片理解失败：\(error.localizedDescription)"
            return
        }

        let provider: ChatModelProvider
        do {
            provider = try container.provider(for: config)
        } catch {
            message = "图片理解失败：\(error.localizedDescription)"
            return
        }

        let prompt = caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "请描述这张图片的内容，并指出值得注意的细节。"
            : caption

        busy = true
        message = nil
        summary = ""
        defer {
            busy = false
            busyText = ""
        }

        for (offset, index) in targets.enumerated() {
            busyText = targets.count == 1
                ? "正在理解…"
                : "第 \(offset + 1)/\(targets.count) 张分析中"
            entries[index].isAnalyzing = true
            entries[index].result = ""
            entries[index].errorText = nil
            await analyzeEntry(at: index, prompt: prompt, config: config, provider: provider)
            entries[index].isAnalyzing = false
        }

        rebuildSummary()
    }

    private func analyzeEntry(
        at index: Int,
        prompt: String,
        config: ModelConfig,
        provider: ChatModelProvider
    ) async {
        guard let attachmentID = entries[index].attachmentID,
              let imageData = entries[index].jpegData else {
            entries[index].errorText = "图片未入库，无法分析"
            return
        }

        do {
            let analysis = try await container.imageAnalyses.create(
                conversationID: nil,
                messageID: nil,
                attachmentIDs: [attachmentID],
                prompt: prompt,
                modelConfigID: config.id,
                at: Clock.nowMillis()
            )

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
                try? await container.imageAnalyses.finish(
                    id: analysis.id,
                    result: "",
                    status: "failed",
                    at: Clock.nowMillis()
                )
                entries[index].errorText = "模型没有返回内容"
                return
            }
            try await container.imageAnalyses.finish(
                id: analysis.id,
                result: trimmed,
                status: "done",
                at: Clock.nowMillis()
            )
            entries[index].result = trimmed
        } catch {
            entries[index].errorText = "图片理解失败：\(error.localizedDescription)"
        }
    }

    /// 合并所有成功结果：单张时就是原始结论，多张时按图片编号分段
    private func rebuildSummary() {
        let successes = entries.enumerated().filter { !$0.element.result.isEmpty }
        guard !successes.isEmpty else {
            summary = ""
            return
        }
        if entries.count == 1 {
            summary = successes[0].element.result
            return
        }
        summary = successes
            .map { "【图片 \($0.offset + 1)】\n\($0.element.result)" }
            .joined(separator: "\n\n")
    }
}

/// 单张图片在本次多图分析中的状态（D71）
private struct ImageUnderstandingEntry: Identifiable {
    let id = UUID()
    var image: UIImage?
    var jpegData: Data?
    var attachmentID: String?
    var ocrText = ""
    var result = ""
    var errorText: String?
    var isAnalyzing = false
}

private enum ImageUnderstandingLoadError: LocalizedError {
    case unreadable
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .unreadable: return "无法读取这张图片"
        case .encodeFailed: return "图片编码失败"
        }
    }
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> Error) throws -> Wrapped {
        guard let value = self else { throw error() }
        return value
    }
}

import SwiftUI
import UniformTypeIdentifiers
import DFCore
import DFData

/// 导出的备份文件包装：原样搬运已加密容器，不做明文转换
struct BackupExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// 备份与恢复（D08 / D09 / D41 / D42 / D43）
@MainActor
struct BackupCenterView: View {
    @EnvironmentObject private var container: AppContainer

    @State private var manifests: [BackupManifest] = []
    @State private var busy = false
    @State private var status: String?
    @State private var restoreCandidate: BackupManifest?
    /// D72：跨设备/来源未知恢复的二次确认
    @State private var showCrossDeviceConfirm = false
    @State private var crossDeviceMessage = ""
    @State private var precheck: RestorePrecheck?
    @State private var showRestoreConfirm = false
    @State private var exportDocument: BackupExportDocument?
    @State private var exportName = "dafeiyu-backup.dfbk"
    @State private var showExporter = false
    /// D41：已授权的外部位置（可多个）
    @State private var locations: [BackupLocation] = []
    @State private var showFolderPicker = false
    @State private var showBackupPicker = false
    /// D43：自动备份保留份数与清理确认
    @State private var retentionCount = 10
    @State private var showPruneConfirm = false

    var body: some View {
        List {
            Section {
                Button {
                    Task { await createBackup() }
                } label: {
                    Label("立即创建加密备份", systemImage: "lock.doc")
                }
                .disabled(busy)
                if busy {
                    ProgressView()
                }
                if let status {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("手动备份")
            } footer: {
                Text("备份默认使用 AES-256-GCM 加密，密钥只在本机 Keychain。恢复前会自动再留一份安全备份。")
            }

            Section {
                if manifests.isEmpty {
                    Text("还没有备份。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manifests) { manifest in
                        manifestRow(manifest)
                    }
                }
            } header: {
                Text("已有备份")
            } footer: {
                Text("“导出”把已加密的备份容器原样存到文件或外部分享位置，不做明文转换；换设备恢复需要同一把本机密钥。")
            }

            Section {
                Stepper(
                    "保留最近 \(retentionCount) 份自动备份",
                    value: $retentionCount,
                    in: 3...50
                )
                .onChange(of: retentionCount) { _, newValue in
                    Task { await saveRetention(newValue) }
                }

                if pruneCandidates.isEmpty {
                    Text("当前没有需要清理的自动备份。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("可清理 \(pruneCandidates.count) 份较早的自动备份（共 \(ByteCountFormatter.string(fromByteCount: pruneBytes, countStyle: .file))）")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button(role: .destructive) {
                        showPruneConfirm = true
                    } label: {
                        Label("清理较早的自动备份", systemImage: "trash")
                    }
                    .disabled(busy)
                }
            } header: {
                Text("保留策略")
            } footer: {
                Text("只清理由本机自动生成的旧备份；已验证、安全备份（恢复前自动留的那份）与手动备份永远不会被自动清理。清理前会先列出条数并要求确认。")
            }

            Section {
                Text("自动备份会持续累积，建议定期清理。清理只影响本机自动生成的旧备份，不影响恢复能力。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section {
                Button {
                    showBackupPicker = true
                } label: {
                    Label("从文件导入备份…", systemImage: "square.and.arrow.down")
                }
                .disabled(busy)
            } header: {
                Text("从文件导入")
            } footer: {
                Text("选择之前导出的 .dfbk 加密备份或 .json 明文备份。导入只登记到本机备份列表，不会自动覆盖当前数据；密钥不同或文件被篡改会直接拒绝。")
            }

            Section {
                ForEach(locations) { location in
                    HStack {
                        Label(location.name, systemImage: "externaldrive")
                        Spacer()
                        Button("移除", role: .destructive) {
                            Task { await removeLocation(location) }
                        }
                        .font(.caption)
                    }
                }
                if locations.count < BackupLocationBook.maxCount {
                    Button {
                        showFolderPicker = true
                    } label: {
                        Label(locations.isEmpty ? "选择外部备份目录…" : "添加外部位置…", systemImage: "folder.badge.plus")
                    }
                    .disabled(busy)
                }
                if !locations.isEmpty {
                    Button("清除全部授权", role: .destructive) {
                        Task { await clearLocations() }
                    }
                    .disabled(busy)
                }
            } header: {
                Text("外部位置（\(locations.count)/\(BackupLocationBook.maxCount)）")
            } footer: {
                Text("通过系统文件选择器授权目录（可选 iCloud Drive 或第三方网盘在「文件」里的位置）；每个位置各自独立复制，一个失败不影响其他位置。厂商 OAuth 云盘需要 App 注册与密钥，仍未内置。")
            }
        }
        .navigationTitle("备份与恢复")
        .scrollContentBackground(.hidden)
        .background(DFColor.canvas)
        .task {
            await reload()
            locations = await ExternalBackupLocation.load(settings: container.settings)
        }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            Task { await handleFolderPick(result) }
        }
        .fileImporter(
            isPresented: $showBackupPicker,
            allowedContentTypes: [.data, .json],
            allowsMultipleSelection: false
        ) { result in
            Task { await handleBackupPick(result) }
        }
        .alert("恢复这份备份？", isPresented: $showRestoreConfirm) {
            Button("开始恢复", role: .destructive) {
                Task { await restore() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(restoreMessage)
        }
        .alert("这是其他位置或设备的备份", isPresented: $showCrossDeviceConfirm) {
            Button("整体替换本机数据", role: .destructive) {
                Task { await restore(confirmedCrossDevice: true) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(crossDeviceMessage)
        }
        .confirmationDialog(
            "清理较早的自动备份？",
            isPresented: $showPruneConfirm,
            titleVisibility: .visible
        ) {
            Button("清理 \(pruneCandidates.count) 份", role: .destructive) {
                Task { await pruneOldBackups() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除 \(pruneCandidates.count) 份较早的自动备份（共 \(ByteCountFormatter.string(fromByteCount: pruneBytes, countStyle: .file))）。已验证、安全备份与手动备份不受影响，删除后无法恢复。")
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .data,
            defaultFilename: exportName
        ) { result in
            switch result {
            case .success(let url):
                status = "已导出：\(url.lastPathComponent)"
            case .failure(let error):
                status = "导出失败：\(error.localizedDescription)"
            }
            exportDocument = nil
        }
    }

    private func manifestRow(_ manifest: BackupManifest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(kindTitle(manifest.kind))
                    .font(.system(size: 14, weight: .medium))
                if manifest.isEncrypted {
                    Label("加密", systemImage: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(DFColor.primary)
                }
                Spacer()
                Text(byteText(manifest.byteSize))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(dateText(manifest.createdAt))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                if let verifiedAt = manifest.verifiedAt {
                    Text("已校验 \(dateText(verifiedAt))")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                if manifest.isUsable {
                    Button("校验") {
                        Task { await verify(manifest) }
                    }
                    .font(.caption)
                    Button("恢复") {
                        Task { await prepareRestore(manifest) }
                    }
                    .font(.caption)
                    Button("导出") {
                        Task { await prepareExport(manifest) }
                    }
                    .font(.caption)
                    if !locations.isEmpty {
                        Button("备份到 \(locations.count) 个位置") {
                            Task { await copyToExternal(manifest) }
                        }
                        .font(.caption)
                    }
                } else {
                    Text("不可用（\(manifest.status.rawValue)）")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private var restoreMessage: String {
        guard let precheck else { return "恢复会替换当前数据。" }
        var lines = [
            "会替换当前会话 / 消息 / 记忆 / 日记 / 人格等数据。",
            "备份库版本：\(precheck.backupSchemaVersion)",
            "当前库版本：\(precheck.currentSchemaVersion)",
            "内容：\(precheck.itemCountsJSON)",
            "恢复前会自动创建安全备份。"
        ]
        if !precheck.isCompatible {
            lines.insert("版本不兼容，无法恢复。", at: 0)
        }
        return lines.joined(separator: "\n")
    }

    private func reload() async {
        do {
            manifests = try await container.backups.manifests(kind: nil, limit: 200)
            if let raw = try? await container.settings.string(for: Self.retentionKey),
               let value = Int(raw) {
                retentionCount = min(max(value, 3), 50)
            }
        } catch {
            status = "读取备份列表失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 保留策略（D43）

    /// 设置键：自动备份保留份数
    private static let retentionKey = "backup.retention.count"

    /// 可清理的旧自动备份：只挑自动/增量类、已完成、未验证、非安全备份
    private var pruneCandidates: [BackupManifest] {
        manifests
            .filter { manifest in
                (manifest.kind == .automatic || manifest.kind == .incremental)
                    && manifest.isUsable
                    && manifest.verifiedAt == nil
            }
            .sorted { $0.createdAt > $1.createdAt }
            .dropFirst(retentionCount)
            .map { $0 }
    }

    private var pruneBytes: Int64 {
        pruneCandidates.reduce(0) { $0 + $1.byteSize }
    }

    private func saveRetention(_ value: Int) async {
        do {
            try await container.settings.set(String(value), for: Self.retentionKey)
        } catch {
            status = "保存保留份数失败：\(error.localizedDescription)"
        }
    }

    /// 用户主动确认后的清理：逐条删除，失败只影响该条
    private func pruneOldBackups() async {
        busy = true
        defer { busy = false }
        var removed = 0
        var failed = 0
        for manifest in pruneCandidates {
            do {
                try await container.backups.delete(id: manifest.id)
                removed += 1
            } catch {
                failed += 1
            }
        }
        status = failed == 0
            ? "已清理 \(removed) 份较早的自动备份"
            : "已清理 \(removed) 份，\(failed) 份删除失败（可稍后重试）"
        await reload()
    }

    private func createBackup() async {
        busy = true
        defer { busy = false }
        do {
            let manifest = try await container.backupService.createBackup(kind: .manual)
            status = "已创建：\(kindTitle(manifest.kind)) · \(byteText(manifest.byteSize))"
            await reload()
        } catch {
            status = "创建失败：\(error.localizedDescription)"
        }
    }

    private func verify(_ manifest: BackupManifest) async {
        busy = true
        defer { busy = false }
        do {
            let result = try await container.backupService.verify(manifestID: manifest.id)
            if result.sha256Matches && result.decrypted {
                status = "校验通过：\(result.itemCountsJSON)"
            } else {
                status = "校验失败：校验和不一致或无法解密"
            }
            await reload()
        } catch {
            status = "校验失败：\(error.localizedDescription)"
        }
    }

    private func prepareRestore(_ manifest: BackupManifest) async {
        busy = true
        defer { busy = false }
        do {
            precheck = try await container.backupService.previewRestore(manifestID: manifest.id)
            restoreCandidate = manifest
            showRestoreConfirm = true
        } catch {
            status = "无法恢复：\(error.localizedDescription)"
        }
    }

    private var mirror: BackupMirrorService {
        BackupMirrorService(settings: container.settings, backupService: container.backupService)
    }

    private func handleFolderPick(_ result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                locations = try await ExternalBackupLocation.add(url: url, settings: container.settings)
                status = "外部位置已授权：\(url.lastPathComponent)（当前 \(locations.count) 个）"
            } catch {
                status = "保存目录授权失败：\(error.localizedDescription)"
            }
        case .failure(let error):
            status = "选择目录失败：\(error.localizedDescription)"
        }
    }

    /// D42：从「文件」导入备份，只登记清单，不自动恢复
    private func handleBackupPick(_ result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            busy = true
            defer { busy = false }
            do {
                let manifest = try await container.backupService.importBackupFile(from: url)
                status = "已导入：\(manifest.fileName)（可在列表里校验或恢复）"
                await reload()
            } catch {
                status = "导入失败：\(error.localizedDescription)"
            }
        case .failure(let error):
            status = "选择文件失败：\(error.localizedDescription)"
        }
    }

    private func removeLocation(_ location: BackupLocation) async {
        do {
            locations = try await ExternalBackupLocation.remove(id: location.id, settings: container.settings)
            status = "已移除外部位置：\(location.name)（不会删除已复制出去的文件）"
        } catch {
            status = "移除位置失败：\(error.localizedDescription)"
        }
    }

    private func clearLocations() async {
        do {
            try await ExternalBackupLocation.clearAll(settings: container.settings)
            locations = []
            status = "已清除全部外部位置授权（不会删除已复制出去的文件）"
        } catch {
            status = "清除授权失败：\(error.localizedDescription)"
        }
    }

    private func copyToExternal(_ manifest: BackupManifest) async {
        busy = true
        defer { busy = false }
        let results = await mirror.copyToAll(manifest)
        status = BackupMirrorSummary.text(for: results)
    }

    /// 读取备份容器原文件，交给系统导出面板（文件 / 外部分享）
    private func prepareExport(_ manifest: BackupManifest) async {
        busy = true
        defer { busy = false }
        do {
            let url = container.backupService.fileURL(for: manifest)
            let data = try Data(contentsOf: url)
            exportDocument = BackupExportDocument(data: data)
            exportName = manifest.fileName
            showExporter = true
        } catch {
            status = "读取备份文件失败：\(error.localizedDescription)"
        }
    }

    private func restore(confirmedCrossDevice: Bool = false) async {
        guard let candidate = restoreCandidate else { return }
        busy = true
        defer { busy = false }
        do {
            let log = try await container.backupService.restore(
                manifestID: candidate.id,
                confirmedCrossDevice: confirmedCrossDevice
            )
            status = log.status == "completed"
                ? "恢复完成，已重建检索索引。"
                : "恢复未完成：\(log.error ?? "未知原因")"
            await reload()
        } catch BackupService.RestoreGuardError.confirmationRequired(let reason) {
            // 跨设备 / 来源未知：必须由用户明确同意整体替换
            crossDeviceMessage = reason
            showCrossDeviceConfirm = true
        } catch BackupService.RestoreGuardError.blocked(let reason) {
            status = "无法恢复：\(reason)"
        } catch {
            status = "恢复失败（原数据未受影响）：\(error.localizedDescription)"
        }
    }

    private func kindTitle(_ kind: BackupKind) -> String {
        switch kind {
        case .manual: return "手动备份"
        case .automatic: return "自动备份"
        case .incremental: return "增量备份"
        case .external: return "外部导出"
        case .safety: return "恢复前安全备份"
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func dateText(_ millis: Int64) -> String {
        Date(timeIntervalSince1970: Double(millis) / 1000)
            .formatted(date: .numeric, time: .shortened)
    }
}

import SwiftUI
import DFCore

/// 备份与恢复（D08 / D09 / D41 / D42 / D43）
@MainActor
struct BackupCenterView: View {
    @EnvironmentObject private var container: AppContainer

    @State private var manifests: [BackupManifest] = []
    @State private var busy = false
    @State private var status: String?
    @State private var restoreCandidate: BackupManifest?
    @State private var precheck: RestorePrecheck?
    @State private var showRestoreConfirm = false

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
            }

            Section {
                Text("已验证与安全备份不会被自动清理；保留数量可在后续版本按需调整。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .navigationTitle("备份与恢复")
        .scrollContentBackground(.hidden)
        .background(DFColor.canvas)
        .task { await reload() }
        .alert("恢复这份备份？", isPresented: $showRestoreConfirm) {
            Button("开始恢复", role: .destructive) {
                Task { await restore() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(restoreMessage)
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
            manifests = try await container.backups.manifests(kind: nil, limit: 30)
        } catch {
            status = "读取备份列表失败：\(error.localizedDescription)"
        }
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

    private func restore() async {
        guard let candidate = restoreCandidate else { return }
        busy = true
        defer { busy = false }
        do {
            let log = try await container.backupService.restore(manifestID: candidate.id)
            status = log.status == "completed"
                ? "恢复完成，已重建检索索引。"
                : "恢复未完成：\(log.error ?? "未知原因")"
            await reload()
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

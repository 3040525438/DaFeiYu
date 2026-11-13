import SwiftUI
import DFCore

@MainActor
struct ModelConfigEditor: View {
    let container: AppContainer
    let existing: ModelConfig?

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var modelID: String = ""
    @State private var apiKey: String = ""
    @State private var errorText: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("例如：主力模型", text: $name)
                }

                Section {
                    TextField("https://example.com/v1", text: $baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("填写到 /v1 即可，程序会自动追加 /chat/completions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("接口地址")
                }

                Section("模型 ID") {
                    TextField("例如：deepseek-chat", text: $modelID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    SecureField(existing == nil ? "sk-..." : "留空则保留原密钥", text: $apiKey)
                    Text("密钥写入系统 Keychain，不落数据库，也不随备份导出。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("API Key")
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(existing == nil ? "添加模型" : "编辑模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task { await save() }
                    }
                    .disabled(isSaving || !canSave)
                }
            }
            .onAppear(perform: loadExisting)
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loadExisting() {
        guard let existing else { return }
        name = existing.name
        baseURL = existing.baseURL
        modelID = existing.modelID
    }

    private func save() async {
        errorText = nil

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            let url = URL(string: trimmedBase),
            let scheme = url.scheme,
            scheme.hasPrefix("http"),
            url.host != nil
        else {
            errorText = "接口地址必须是 http(s) 开头的完整 URL"
            return
        }

        guard !trimmedName.isEmpty, !trimmedModel.isEmpty else {
            errorText = "名称和模型 ID 不能为空"
            return
        }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if existing == nil && trimmedKey.isEmpty {
            errorText = "首次添加时必须填写 API Key"
            return
        }

        isSaving = true
        defer { isSaving = false }

        var config = existing ?? ModelConfig(
            name: trimmedName,
            baseURL: trimmedBase,
            modelID: trimmedModel
        )
        config.name = trimmedName
        config.baseURL = trimmedBase
        config.modelID = trimmedModel

        do {
            if !trimmedKey.isEmpty {
                try container.secureStore.set(trimmedKey, for: config.keyRef)
            }
            try await container.modelConfigs.save(config)

            if existing == nil {
                let all = try await container.modelConfigs.all()
                if all.count == 1 {
                    try await container.modelConfigs.makeDefault(id: config.id)
                }
            }

            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

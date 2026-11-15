import SwiftUI
import DFCore
import DFData

/// D10：预算与成本中心。
///
/// 展示口径与判定口径一致：已确认费用 / 估算费用 / 无法计量条数分开呈现，
/// 未知费用绝不显示为 0，而是按"保守单价 × 条数"计入合计。
@MainActor
struct BudgetCenterView: View {
    @EnvironmentObject private var container: AppContainer

    @State private var dailyText = ""
    @State private var perCallText = ""
    @State private var autonomyText = ""
    @State private var reserveText = "0.02"

    @State private var spend: BudgetSpend = .zero
    @State private var records: [CostRecord] = []
    @State private var limits = BudgetLimits.default
    @State private var models: [ModelConfig] = []
    @State private var pricingDrafts: [String: PricingDraft] = [:]

    @State private var statusMessage: String?
    @State private var isSaving = false

    private struct PricingDraft: Equatable {
        var input = ""
        var output = ""
    }

    var body: some View {
        List {
            todaySection
            limitsSection
            pricingSection
            recordsSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DFColor.canvas)
        .tint(DFColor.primary)
        .navigationTitle("预算与成本")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
    }

    // MARK: - 今日花费

    private var todaySection: some View {
        Section {
            LabeledContent("已确认费用", value: yuan(spend.confirmedYuan))
            LabeledContent("估算费用", value: yuan(spend.estimatedYuan))
            LabeledContent("无法计量的调用", value: "\(spend.unknownCount) 次")
            LabeledContent("保守合计", value: yuan(effectiveSpend))
            LabeledContent("自主行动", value: yuan(autonomyEffectiveSpend))
            if spend.unknownCount > 0 {
                Text("无法计量的调用按每次 \(yuan(limits.unknownReserveYuan)) 保守计入，不会当作 0。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } header: {
            Text("今日花费（\(container.budget.todayKey())）")
        }
    }

    private var effectiveSpend: Double {
        spend.effectiveYuan(unknownReserveYuan: limits.unknownReserveYuan)
    }

    private var autonomyEffectiveSpend: Double {
        spend.effectiveAutonomyYuan(unknownReserveYuan: limits.unknownReserveYuan)
    }

    // MARK: - 上限

    private var limitsSection: some View {
        Section {
            limitRow(title: "每日总预算", text: $dailyText, hint: "聊天 + 自主行动")
            limitRow(title: "单次调用预算", text: $perCallText, hint: "单次请求预估上限")
            limitRow(title: "自主行动每日预算", text: $autonomyText, hint: "只约束后台主动行为")
            HStack {
                Text("未知费用保守单价")
                Spacer()
                TextField("0.02", text: $reserveText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90)
                Text("元/次").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                Task { await saveLimits() }
            } label: {
                if isSaving {
                    ProgressView()
                } else {
                    Text("保存预算设置")
                }
            }
            .disabled(isSaving)
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("预算上限")
        } footer: {
            Text("留空表示不限制。预算判定在读当日花费 + 写入预占的同一个事务里完成，并发请求无法绕过上限。")
        }
    }

    private func limitRow(title: String, text: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                TextField("不限", text: text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90)
                Text("元").font(.caption).foregroundStyle(.secondary)
            }
            Text(hint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 模型单价

    private var pricingSection: some View {
        Section {
            if models.isEmpty {
                Text("还没有模型配置。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(models) { model in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.name)
                            .font(.system(size: 15, weight: .medium))
                        Text(model.modelID)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        HStack(spacing: 12) {
                            priceField(
                                title: "输入",
                                text: pricingBinding(model.modelID, keyPath: \.input)
                            )
                            priceField(
                                title: "输出",
                                text: pricingBinding(model.modelID, keyPath: \.output)
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                Button {
                    Task { await savePricing() }
                } label: {
                    Text("保存模型单价")
                }
                .disabled(isSaving)
            }
        } header: {
            Text("模型单价（元 / 千 token）")
        } footer: {
            Text("不填单价时，该模型的调用会被记为「无法计量」，按上面的保守单价参与预算判定，而不是当作免费。")
        }
    }

    private func priceField(title: String, text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("未配置", text: text)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - 记录

    private var recordsSection: some View {
        Section {
            if records.isEmpty {
                Text("今天还没有成本记录。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(records, id: \.id) { record in
                    recordRow(record)
                }
            }
        } header: {
            Text("成本明细（最近 30 条）")
        } footer: {
            Text("每条记录保留场景、模型、状态与费用口径，用于审计与对账。")
        }
    }

    private func recordRow(_ record: CostRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(record.scope == .autonomy ? "自主" : "聊天")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(DFColor.primarySoft)
                    .foregroundStyle(DFColor.primary)
                    .clipShape(Capsule())
                Text(record.modelID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(costText(record))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
            }
            Text("\(self.statusText(record)) · \(self.kindText(record.costKind)) · \(self.timeText(record.createdAt))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if let note = record.note, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func costText(_ record: CostRecord) -> String {
        if let cost = record.costYuan {
            return yuan(cost)
        }
        return "未知"
    }

    private func statusText(_ record: CostRecord) -> String {
        switch record.status {
        case "reserved": return "预占中"
        case "settled": return "已结算"
        case "failed": return "失败"
        case "cancelled": return "已取消"
        default: return record.status
        }
    }

    private func kindText(_ kind: CostKind) -> String {
        switch kind {
        case .confirmed: return "已确认"
        case .estimated: return "估算"
        case .unavailable: return "无法计量"
        }
    }

    private func timeText(_ millis: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(millis) / 1000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func yuan(_ value: Double) -> String {
        String(format: "¥%.2f", value)
    }

    // MARK: - 绑定

    private func pricingBinding(
        _ modelID: String,
        keyPath: WritableKeyPath<PricingDraft, String>
    ) -> Binding<String> {
        Binding(
            get: { pricingDrafts[modelID]?[keyPath: keyPath] ?? "" },
            set: { newValue in
                var draft = pricingDrafts[modelID] ?? PricingDraft()
                draft[keyPath: keyPath] = newValue
                pricingDrafts[modelID] = draft
            }
        )
    }

    // MARK: - 读写

    private func reload() async {
        do {
            let loaded = try await container.budget.limits()
            limits = loaded
            dailyText = text(for: loaded.dailyYuan)
            perCallText = text(for: loaded.perCallYuan)
            autonomyText = text(for: loaded.autonomyDailyYuan)
            reserveText = String(format: "%.2f", loaded.unknownReserveYuan)

            models = try await container.modelConfigs.all()
            var drafts: [String: PricingDraft] = [:]
            for model in models where drafts[model.modelID] == nil {
                let pricing = try await container.budget.pricing(modelID: model.modelID)
                drafts[model.modelID] = PricingDraft(
                    input: pricing.map { String(format: "%.4f", $0.inputPerThousandYuan) } ?? "",
                    output: pricing.map { String(format: "%.4f", $0.outputPerThousandYuan) } ?? ""
                )
            }
            pricingDrafts = drafts

            spend = try await container.budget.snapshot()
            records = try await container.budget.records(limit: 30)
        } catch {
            statusMessage = "读取预算失败：\(error.localizedDescription)"
        }
    }

    private func text(for value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%.2f", value)
    }

    private func parseOptional(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    private func saveLimits() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = BudgetLimits(
                dailyYuan: parseOptional(dailyText),
                perCallYuan: parseOptional(perCallText),
                autonomyDailyYuan: parseOptional(autonomyText),
                unknownReserveYuan: parseOptional(reserveText) ?? 0.02
            )
            try await container.budget.saveLimits(updated)
            statusMessage = "预算设置已保存"
            await reload()
        } catch {
            statusMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    private func savePricing() async {
        isSaving = true
        defer { isSaving = false }
        do {
            for model in models {
                guard let draft = pricingDrafts[model.modelID] else { continue }
                let input = parseOptional(draft.input)
                let output = parseOptional(draft.output)
                if input == nil, output == nil {
                    try await container.budget.clearPricing(modelID: model.modelID)
                } else if let input, let output {
                    try await container.budget.savePricing(
                        ModelPricing(
                            inputPerThousandYuan: input,
                            outputPerThousandYuan: output
                        ),
                        modelID: model.modelID
                    )
                }
            }
            statusMessage = "模型单价已保存"
            await reload()
        } catch {
            statusMessage = "保存失败：\(error.localizedDescription)"
        }
    }
}

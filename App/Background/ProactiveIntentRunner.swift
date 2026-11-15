import Foundation
import UserNotifications
import DFCore
import DFData

/// N-20：后台唤醒时的"生成意图 → 过五重闸门 → 写入会话 → 通知"闭环。
///
/// 边界：
/// - 只处理 `message` / `suggestion` 两类任务，其余类型保持原样；
/// - 没有默认模型配置时直接返回，不认领任务，避免把重试次数耗光；
/// - 闸门拦截属于正常结果（skipped），只有真正异常才记 failed；
/// - D10：每次生成前在 `BudgetService` 里预占自主预算，结束后按真实用量结算，
///   失败保留预占金额，闸门拿到的"今日已花"来自真实成本台账而不是固定 0。
final class ProactiveIntentRunner: @unchecked Sendable {
    private static let supportedKinds: Set<String> = [
        ProactiveTrigger.message.rawValue,
        ProactiveTrigger.suggestion.rawValue
    ]
    private static let enabledKey = "autonomy.intent.enabled"
    /// 自主生成的最大输出 token（与 ProactiveIntentService 默认值一致）
    private static let maxGenerationTokens = 320
    /// 无法精确获得提示词用量时的保守输入估算
    private static let estimatedPromptTokens = 1200

    private let container: AppContainer

    init(container: AppContainer) {
        self.container = container
    }

    /// 返回本次真正投递成功的条数。
    func runDueIntents(limit: Int = 2) async -> Int {
        let enabled = (try? await container.settings.string(for: Self.enabledKey)) != "false"
        guard enabled else { return 0 }
        guard let config = try? await container.modelConfigs.defaultConfig() else { return 0 }
        guard let tasks = try? await container.autonomy.dueTasks(limit: max(1, limit)) else { return 0 }

        var delivered = 0
        for task in tasks where Self.supportedKinds.contains(task.kind) {
            guard let claimed = try? await container.autonomy.claim(taskID: task.id) else { continue }
            do {
                let conversation = try await container.conversations.ensureMainConversation(title: "大肥鱼")
                if let target = claimed.conversationID, target != conversation.id {
                    try? await container.autonomy.finish(
                        taskID: claimed.id,
                        status: .skipped,
                        resultJSON: "{\"reason\":\"任务属于其他会话\"}"
                    )
                    continue
                }

                let trigger = ProactiveTrigger(rawValue: claimed.kind) ?? .message
                let context = try await makeContext(
                    conversationID: conversation.id,
                    topicID: claimed.topicID
                )

                // D10：生成前按真实配置预占自主预算；预算不足时任务跳过，不消耗重试次数
                let limits = try await container.budget.limits()
                let pricing = try? await container.budget.pricing(modelID: config.modelID)
                let estimated = pricing?.estimatedCost(
                    promptTokens: Self.estimatedPromptTokens,
                    maxCompletionTokens: Self.maxGenerationTokens
                ) ?? 0
                let reservationID: String
                do {
                    reservationID = try await container.budget.reserve(
                        scope: .autonomy,
                        estimatedYuan: estimated,
                        provider: config.providerKind,
                        modelID: config.modelID,
                        limits: limits
                    )
                } catch {
                    try? await container.autonomy.finish(
                        taskID: claimed.id,
                        status: .skipped,
                        resultJSON: "{\"reason\":\"预算不足：\(error.localizedDescription)\"}"
                    )
                    continue
                }

                let proposal: ProactiveIntentService.Proposal
                do {
                    let provider = try container.provider(for: config)
                    proposal = try await container.intents.generate(
                        trigger: trigger,
                        context: context,
                        provider: provider,
                        model: config.modelID,
                        maxTokens: Self.maxGenerationTokens
                    )
                } catch {
                    // 生成失败：保留预占金额（服务端可能已计费），任务按失败处理
                    try? await container.budget.fail(
                        reservationID: reservationID,
                        reason: error.localizedDescription
                    )
                    try? await container.autonomy.finish(
                        taskID: claimed.id,
                        status: .failed,
                        error: error.localizedDescription
                    )
                    continue
                }

                try? await container.budget.settle(
                    reservationID: reservationID,
                    usage: proposal.usage,
                    pricing: pricing,
                    fallbackPromptTokens: Self.estimatedPromptTokens,
                    fallbackCompletionTokens: TokenEstimator.estimate(
                        proposal.candidateText ?? ""
                    ),
                    modelID: config.modelID
                )

                guard let text = proposal.candidateText else {
                    try? await container.autonomy.finish(
                        taskID: claimed.id,
                        status: .skipped,
                        resultJSON: "{\"intent_id\":\"\(proposal.intent.id)\",\"reason\":\"模型判断现在不适合打扰\"}"
                    )
                    continue
                }

                let status = await container.notifications.authorizationStatus()
                let authorized = status == .authorized || status == .provisional || status == .ephemeral
                // D10：闸门使用真实成本快照（含未知费用的保守估算）
                let spend = (try? await container.budget.snapshot()) ?? .zero
                let budgetContext = AutonomyBudgetContext(
                    limits: limits,
                    spend: spend,
                    estimatedNextCallYuan: 0
                )
                let result = try await container.intents.dispatch(
                    intentID: proposal.intent.id,
                    text: text,
                    todaySpentYuan: spend.knownTotalYuan,
                    notificationsAuthorized: authorized,
                    runTrigger: "background",
                    budget: budgetContext
                )

                switch result {
                case .delivered(_, let proactiveID, _, _):
                    let records = try? await container.proactive.list(limit: 50)
                    if let record = records?.first(where: { $0.id == proactiveID }) {
                        await container.notifications.deliver(record)
                    }
                    delivered += 1
                    try? await container.autonomy.finish(
                        taskID: claimed.id,
                        status: .done,
                        resultJSON: "{\"intent_id\":\"\(proposal.intent.id)\",\"proactive_id\":\"\(proactiveID)\"}"
                    )
                case .blocked(let reason, let runID):
                    try? await container.autonomy.finish(
                        taskID: claimed.id,
                        status: .skipped,
                        resultJSON: "{\"intent_id\":\"\(proposal.intent.id)\",\"blocked\":\"\(reason)\",\"run_id\":\"\(runID)\"}"
                    )
                }
            } catch {
                try? await container.autonomy.finish(
                    taskID: claimed.id,
                    status: .failed,
                    error: error.localizedDescription
                )
            }
        }
        return delivered
    }

    // MARK: - 上下文

    private func makeContext(
        conversationID: String,
        topicID: String?
    ) async throws -> ProactiveIntentService.IntentContext {
        let recent = try await container.messages.recentMessages(in: conversationID, limit: 12)
        let turns = recent.map { message -> String in
            switch message.role {
            case .user: return "用户：\(String(message.text.prefix(160)))"
            case .assistant: return "大肥鱼：\(String(message.text.prefix(160)))"
            default: return message.text
            }
        }
        let suppressed = (try? await container.proactive.suppressedTriggerKinds()) ?? []
        let hints = suppressed.sorted().map { "用户此前关闭了 \($0) 类型的主动行为，请更谨慎" }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm EEE"

        return ProactiveIntentService.IntentContext(
            conversationID: conversationID,
            topicID: topicID,
            localTimeText: formatter.string(from: Date()),
            recentTurns: turns,
            candidateMemories: [],
            feedbackHints: hints
        )
    }
}

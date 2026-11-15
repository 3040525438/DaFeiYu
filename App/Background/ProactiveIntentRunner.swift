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
/// - 预算参数暂按 0 传入：D10 成本记账尚未接入，不能假装已有花费统计。
final class ProactiveIntentRunner: @unchecked Sendable {
    private static let supportedKinds: Set<String> = [
        ProactiveTrigger.message.rawValue,
        ProactiveTrigger.suggestion.rawValue
    ]
    private static let enabledKey = "autonomy.intent.enabled"

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
                let provider = try container.provider(for: config)
                let proposal = try await container.intents.generate(
                    trigger: trigger,
                    context: context,
                    provider: provider,
                    model: config.modelID
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
                let result = try await container.intents.dispatch(
                    intentID: proposal.intent.id,
                    text: text,
                    todaySpentYuan: 0,
                    notificationsAuthorized: authorized,
                    runTrigger: "background"
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

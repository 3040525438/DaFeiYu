import Foundation

// MARK: - iOS 后台任务与远程调度的说明（D21）
//
// iOS 不保证后台任务按时执行；远程调度会产生模型费用并涉及数据外发。
// 这里集中一份如实说明，供设置页展示，避免文案各处漂移。

/// 后台与运行方式的说明文本
public struct BackgroundDisclosure: Sendable, Equatable {
    /// 后台任务实际会做什么
    public var whatRuns: [String]
    /// 时间保证说明
    public var timing: String
    /// 成本说明
    public var cost: String
    /// 隐私说明
    public var privacy: String

    public init(whatRuns: [String], timing: String, cost: String, privacy: String) {
        self.whatRuns = whatRuns
        self.timing = timing
        self.cost = cost
        self.privacy = privacy
    }
}

public enum BackgroundExecutionPolicy {
    /// 系统是否保证后台任务按时执行。**永远为 false**，任何 UI 不得承诺"准点"。
    public static let timingGuaranteed = false

    public static let disclosure = BackgroundDisclosure(
        whatRuns: [
            "每日整理与备份：在系统允许的时间片内补算未完成的任务",
            "主动关心：按你设定的频率、免打扰时段与每日上限决定是否开口",
            "记忆整理与反思：只在本地数据库内结算，除非主动消息需要调用云端模型"
        ],
        timing: "iOS 只决定「什么时候有空跑」，不保证准点。可能提前、延后，或在长时间不打开 App 时暂缓；下次启动会补算未完成的任务。",
        cost: "主动行为若调用云端模型，会按服务商的单价产生费用，并计入「预算与成本」；超出预算时自动行为会被拦截，而不是悄悄扣费。",
        privacy: "后台运行时只发送生成当前这条内容所需的最少上下文；不会上传整个数据库、附件原文件或密钥；所有外发都以你已配置的模型服务商为限。"
    )

    /// 距离下次计划的自然语言说明（不承诺准点）
    public static func nextRunExplanation(scheduledAt: Int64?, now: Int64) -> String {
        guard let scheduledAt else {
            return "暂未安排下一次后台任务"
        }
        let delta = scheduledAt - now
        if delta <= 0 {
            return "后台任务已到时间，系统会在方便时唤起，可能延后"
        }
        let minutes = Int((Double(delta) / 60_000).rounded(.up))
        if minutes < 60 {
            return "计划约 \(minutes) 分钟后，但系统可能延后"
        }
        let hours = Int((Double(minutes) / 60).rounded(.up))
        return "计划约 \(hours) 小时后，但系统可能延后"
    }
}

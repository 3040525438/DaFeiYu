import Foundation

/// 组关闭后的生命周期回调。
/// P2 的"记忆抽取 / 反思"、P4 的"主动消息"都在此挂载，A1 只定义契约。
public protocol ChatLifecycleObserver: Sendable {
    func groupDidClose(_ group: MessageGroup, messages: [Message]) async
}

/// 编排过程中向 UI 推送的事件。
///
/// 契约（B1-S1 定稿）：
/// - `turnOpened` 是分水岭：该事件一旦 yield，流**永不再 throw**；
/// - `turnOpened` 之后的所有运行期结局只通过 `turnCompleted` / `turnFailed` / `turnCancelled` 表达，
///   三者互斥且必有其一，流随后正常 `finish()`；
/// - `turnOpened` 之前的基础设施级失败（空输入、已有 open 组、找不到 assistant、事务 A 失败）
///   通过 `finish(throwing:)` 抛出，库里不产生新行；
/// - 禁止同一轮的同一错误既发事件又 throw。
public enum OrchestratorEvent: Sendable, Equatable {
    /// 事务 A 已提交：组与新消息均已落库
    case turnOpened(groupID: String, userMessageID: String, assistantMessageID: String)
    /// 流式可见增量：UI 应**追加**到当前 assistant 文本
    case assistantDelta(String)
    /// 定稿正文：UI 应**整体替换**当前 assistant 文本（`finish()` 之后、事务 B 之前/后的一致性文本）
    case assistantReplaced(String)
    /// 正常结束：事务 B 已提交
    case turnCompleted(groupID: String, assistantMessageID: String, citations: [String])
    /// 运行期失败：事务 C 已提交（组 failed / assistant failed）
    case turnFailed(groupID: String, assistantMessageID: String, reason: String)
    /// 用户或生命周期取消：组 aborted / assistant canceled（属正常终止，不是错误）
    case turnCancelled(groupID: String, assistantMessageID: String)
}

/// 对话编排契约：读取历史 → 组装上下文 → 请求模型 → 落库 → 解析引用 → 关组。
///
/// A1 只定义协议与错误类型；B1 在 DFOrchestration 提供唯一实现，
/// 纯逻辑部分（裁剪、解析、校验）由本模块的类型承担。
public protocol ChatOrchestrator: Sendable {
    var observer: ChatLifecycleObserver? { get set }

    /// 发起一轮对话。
    ///
    /// - 返回值：事件流，顺序为 `turnOpened → assistantDelta* → assistantReplaced → 终态事件`。
    /// - 抛出：仅限"首个事件之前"的 `ChatOrchestrationError`（此时库内无新行）。
    func send(text: String, conversationID: String) -> AsyncThrowingStream<OrchestratorEvent, Error>

    /// 重试某个 assistant 回复：新建消息组，旧组与旧消息保持不变。
    ///
    /// - 参数 messageID：**assistant** 消息 id。
    /// - 返回值与抛出语义同 `send`。
    func retry(messageID: String, conversationID: String) -> AsyncThrowingStream<OrchestratorEvent, Error>

    /// 取消当前活跃轮次。
    ///
    /// - 参数 owner：发起该轮次的页面归属 token。只有与活跃轮次的 owner 一致时才生效，
    ///   否则直接返回（0 写入），用于防止旧页面 / 旧 ViewModel / 重复生命周期回调误取消新轮次。
    /// - 幂等：无活跃轮次、或轮次已进入收尾阶段时调用不产生任何状态转换。
    /// - 永不抛错：终态一律通过 `turnCancelled` 事件表达。
    func cancelActiveTurn(owner: UUID) async
}

public enum ChatOrchestrationError: Error, Equatable, Sendable {
    /// 空输入
    case emptyInput
    /// 会话已有 open 组（P1.5 不支持并发开组）
    case groupAlreadyOpen(groupID: String)
    /// 找不到 assistant 消息行
    case assistantMessageMissing
    /// 组状态与操作不匹配（例如对 complete 组执行取消）
    case invalidGroupState(expected: MessageGroupStatus, actual: MessageGroupStatus)
    /// 落库失败（事务已回滚）
    case persistenceFailed(reason: String)
    /// 任务被取消（组应转为 aborted）
    case cancelled
}

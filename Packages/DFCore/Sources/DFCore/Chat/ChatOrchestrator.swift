import Foundation

/// 组关闭后的生命周期回调。
/// P2 的"记忆抽取 / 反思"、P4 的"主动消息"都在此挂载，A1 只定义契约。
public protocol ChatLifecycleObserver: Sendable {
    func groupDidClose(_ group: MessageGroup, messages: [Message]) async
}

/// 对话编排契约：读取历史 → 组装上下文 → 请求模型 → 落库 → 解析引用 → 关组。
///
/// A1 只定义协议与错误类型；实现在 B1 的 App 层提供，
/// 纯逻辑部分（裁剪、解析、校验）已由本模块的类型承担。
public protocol ChatOrchestrator: Sendable {
    var observer: ChatLifecycleObserver? { get set }
    func send(text: String, conversationID: String) async throws
    func retry(messageID: String, conversationID: String) async throws
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

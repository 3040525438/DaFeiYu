import Foundation

// MARK: - 数据流向目录（D59）
//
// 一份"数据到底去了哪里"的清单，界面直接展示，避免用笼统文案描述隐私。
// 这里的内容必须与实际实现一致：改了上传/存储行为，就要同步改这张表。

/// 数据可能的去向
public enum DataFlowDestination: String, Sendable, CaseIterable {
    /// 只在本机（App 沙盒内）
    case onDevice
    /// 会发送给云端模型服务商
    case cloudModel
    /// 只在用户主动选择的外部位置（导出、备份文件）
    case userChosenLocation

    public var displayName: String {
        switch self {
        case .onDevice: return "仅本机"
        case .cloudModel: return "云端模型服务商"
        case .userChosenLocation: return "用户选择的位置"
        }
    }

    /// 是否离开设备
    public var leavesDevice: Bool {
        self != .onDevice
    }
}

public struct DataFlowEntry: Sendable, Equatable, Identifiable {
    public var id: String
    /// 分类（聊天 / 记忆 / 日记 / 人格与关系 / 附件 / 语音 / 备份 / 模型配置 / 诊断）
    public var category: String
    public var title: String
    /// 具体包含哪些内容
    public var contents: String
    public var destination: DataFlowDestination
    public var encryptedAtRest: Bool
    public var canRevoke: Bool
    /// 如何减少或撤销这类数据外流
    public var revokeHint: String
    /// 如何导出或删除
    public var controlHint: String

    public init(
        id: String,
        category: String,
        title: String,
        contents: String,
        destination: DataFlowDestination,
        encryptedAtRest: Bool,
        canRevoke: Bool,
        revokeHint: String,
        controlHint: String
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.contents = contents
        self.destination = destination
        self.encryptedAtRest = encryptedAtRest
        self.canRevoke = canRevoke
        self.revokeHint = revokeHint
        self.controlHint = controlHint
    }
}

public enum DataFlowCatalog {
    /// 固定清单：与当前实现一一对应
    public static let entries: [DataFlowEntry] = [
        DataFlowEntry(
            id: "chat.text",
            category: "聊天",
            title: "聊天消息",
            contents: "你发送的文字、AI 的回复、编辑与撤回留痕",
            destination: .onDevice,
            encryptedAtRest: false,
            canRevoke: true,
            revokeHint: "删除会话或删除全部数据；删除会话默认保留记忆",
            controlHint: "会话内长按消息可删除；设置 → 隐私与安全 → 删除全部数据"
        ),
        DataFlowEntry(
            id: "chat.cloud",
            category: "聊天",
            title: "云端模型请求",
            contents: "本轮用户输入、本轮相关上下文与当前系统提示词",
            destination: .cloudModel,
            encryptedAtRest: false,
            canRevoke: true,
            revokeHint: "关闭云端模型或清空 API Key 后不再发起请求；已发出的请求由服务商按其政策处理",
            controlHint: "设置 → 模型，可更换服务商或清除密钥"
        ),
        DataFlowEntry(
            id: "memory",
            category: "记忆",
            title: "长期记忆与记忆来源",
            contents: "记忆正文、来源、版本、重要度变化、记忆之间的关联",
            destination: .onDevice,
            encryptedAtRest: false,
            canRevoke: true,
            revokeHint: "逐条删除记忆或按来源删除",
            controlHint: "设置 → 数据导出可导出；记忆整理页可删除"
        ),
        DataFlowEntry(
            id: "diary",
            category: "日记",
            title: "每日日记",
            contents: "日记正文、版本历史、语气与标签",
            destination: .onDevice,
            encryptedAtRest: false,
            canRevoke: true,
            revokeHint: "删除对应日记或删除全部数据",
            controlHint: "日记页面删除；设置 → 数据导出"
        ),
        DataFlowEntry(
            id: "persona",
            category: "人格与关系",
            title: "人格、关系与角色状态",
            contents: "人格条目与版本、关系阶段与里程碑、角色情绪状态",
            destination: .onDevice,
            encryptedAtRest: false,
            canRevoke: true,
            revokeHint: "人格成长提案必须由你确认才会生效；核心人格不会被自动改写",
            controlHint: "审批中心逐条确认；设置 → 数据导出"
        ),
        DataFlowEntry(
            id: "attachment",
            category: "附件",
            title: "图片与文件",
            contents: "原图、缩略图、OCR 文本与图片理解结果",
            destination: .onDevice,
            encryptedAtRest: false,
            canRevoke: true,
            revokeHint: "附件库删除未被消息引用的附件；被引用附件需先解除引用",
            controlHint: "附件库可查看引用状态并清理"
        ),
        DataFlowEntry(
            id: "attachment.cloud",
            category: "附件",
            title: "图片理解上传",
            contents: "被选中参与本轮理解的图片（转 JPEG 后）",
            destination: .cloudModel,
            encryptedAtRest: false,
            canRevoke: true,
            revokeHint: "不选图就不会上传；OCR 默认在本机完成",
            controlHint: "图片理解前会提示；可在设置中关闭云端图片理解"
        ),
        DataFlowEntry(
            id: "speech",
            category: "语音",
            title: "语音输入",
            contents: "录音与转写文本",
            destination: .onDevice,
            encryptedAtRest: false,
            canRevoke: true,
            revokeHint: "默认使用设备端转写，音频不上传；仅在切换到云端识别并授权后才会上传",
            controlHint: "设置 → 语音，可切回设备端转写"
        ),
        DataFlowEntry(
            id: "backup",
            category: "备份",
            title: "备份文件",
            contents: "数据库快照（含聊天、记忆、日记、人格与关系）",
            destination: .userChosenLocation,
            encryptedAtRest: true,
            canRevoke: true,
            revokeHint: "默认加密；只写到你自己选择的位置，App 不会自动上传",
            controlHint: "设置 → 备份与恢复，可导出、保留与删除"
        ),
        DataFlowEntry(
            id: "model.config",
            category: "模型配置",
            title: "API Key 与模型配置",
            contents: "服务地址、模型名、API Key",
            destination: .onDevice,
            encryptedAtRest: true,
            canRevoke: true,
            revokeHint: "API Key 只存 Keychain，不写入数据库、不进备份、不进导出",
            controlHint: "设置 → 模型，可修改或清除"
        ),
        DataFlowEntry(
            id: "diagnostics",
            category: "诊断",
            title: "诊断与反馈报告",
            contents: "版本号、表计数、完整性检查结果、错误摘要（已脱敏）",
            destination: .userChosenLocation,
            encryptedAtRest: false,
            canRevoke: true,
            revokeHint: "只有你主动分享时才会离开设备",
            controlHint: "设置 → 关于与诊断，可导出诊断包"
        )
    ]

    /// 所有分类（按首次出现顺序，保持界面稳定）
    public static func categories() -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for entry in entries where !seen.contains(entry.category) {
            seen.insert(entry.category)
            result.append(entry.category)
        }
        return result
    }

    public static func entries(in category: String) -> [DataFlowEntry] {
        entries.filter { $0.category == category }
    }

    /// 会离开设备的数据类数量
    public static var leavingDeviceCount: Int {
        entries.filter { $0.destination.leavesDevice }.count
    }

    /// 一句话总结，放在说明区块顶部
    public static var summary: String {
        "共 \(categories().count) 类数据，其中 \(leavingDeviceCount) 类可能离开设备；云端请求只发送当轮所需内容，API Key 只存 Keychain。"
    }
}

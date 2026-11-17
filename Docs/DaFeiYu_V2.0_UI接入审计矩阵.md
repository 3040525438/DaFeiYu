# DaFeiYu V2.0 UI 接入审计矩阵

> 审计性质：**代码审计 + 分批补齐**。以仓库当前代码为准，历史文档结论只作参考。
> 审计范围：`RootView` / `SettingsView` / `SpaceView` / `ChatView` / 记忆页 / 日记页 / 成长页，以及 D01–D72 逐项 UI 可达性。
> 补齐记录：`d914956`（D13/D14/D19/D48）、`2865a90`（D50/D62/D68）；两笔均已过 `core-tests` 与正式/实验双 Target 编译。
> 结论口径：见到页面文件 + 入口 + 真实 Service 调用 + 持久化，才判 A；只看到页面/按钮但无业务调用，判 B；只有数据层/Service，判 C。
> 未验证项：`build-ipa` 因 macOS runner 未分配被取消（IPA 未产出）；真机 0 项。

---

## 一、审计口径与事实基线

### 1.1 事实基线

| 项 | 事实 |
|---|---|
| 仓库 | `E:\temp_20261113_01\DaFeiYu` |
| App 入口 | `App/DaFeiYuApp.swift:20-49` → `RootView` |
| 依赖装配 | `App/AppContainer.swift:135-262` |
| 导航 | 5 个 Tab，见 `Features/Root/RootView.swift:43-75` |
| 本会话验证能力 | 仅静态代码审计；未编译、未跑测、未真机 |
| 历史文档 | `Docs/DaFeiYu_V2.0_需求追溯矩阵与任务分解.md`（下称“追溯矩阵”） |

### 1.2 状态定义（四档，互斥）

| 状态 | 含义 | 判定标准 |
|---|---|---|
| **A** | 已接入 UI 且真实可用 | 页面 + 入口 + 真实 Service 调用 + 持久化；有加载/成功/失败/空态 |
| **B** | 页面或按钮存在但未接业务 | 占位页、假数据、点了没反应、只读展示且不可操作、局部字段未落库 |
| **C** | 无 UI | 仅有数据层/Service，或完全未实现；用户无法从任何入口使用 |
| **D** | 受 iOS/外部限制 | 已说明限制，不算代码缺陷（如本地推理、厂商 OAuth、真机验收） |

补充口径：

1. 对“纯后台规则类”决策（如发送闸门、自动备份），若已接入真实业务链路且效果能在现有页面观察，可判 A；若完全无可观察入口，判 C。
2. 对“技术底座类”决策（如工具调用、结构化输出），若只有核心库与单测、没有生产调用点，判 C，不按“核心库有文件”判 A。
3. 页面存在但核心动作缺失（例如只有只读展示、没有编辑/回退），判 B 或 C，不因“文件存在”判 A。

### 1.3 与历史文档的冲突（以代码为准）

| 追溯矩阵结论 | 代码事实 | 冲突结论 |
|---|---|---|
| R3/R4 称 72 项中约 70 项有证据（第349-350行） | 初版按 UI 接入口径统计为 A 52 / B 10 / C 7 / D 3；补齐后为 **A 69 / B 0 / C 0 / D 3** | “有代码/有单测”不等于“UI 可用”；剩余 3 项 D 均为本地推理暂缓（ADR-08） |
| D13、D14、D48 标“已实现”（第88、89、143行） | 初版仅本地 `@State`；**已在 2865a90 补齐**：读写 `AutonomyPolicy`，含免打扰/间隔/上限/分项开关 | 初版判 B，现判 A |
| D30 标“已实现”（第115行） | **已在 c3f6e9e 补齐**：`PersonaVersionsView` 可编辑核心提示词与名称，保存即写入 `persona_items` 并留版本 | 初版判 C，现判 A |
| D32 标“已实现”（第117行） | **已在 c3f6e9e 补齐**：成长页「她的反思」列表 + 「现在反思一次」，调用 `ReflectionAutoService.run` | 初版判 C，现判 A |
| D07 标“已实现”（第77行） | **已在 c3f6e9e 补齐**：`PersonaVersionsView` 展示历史版本并支持 `restore`（二次确认） | 初版判 B，现判 A |
| D50 标“已实现（数据层+后台补算）”（第145行） | 初版为静态占位页；**已在 2865a90 补齐**：真实列表 + 收藏/不感兴趣/删除/触发原因 | 初版判 C，现判 A |
| D62 标“已实现有证据”（第162行） | **已在 2865a90 补齐**：同一页新增「自主记录」分页，展示 `autonomy_runs` | 初版判 C，现判 A |
| D67 标“已实现有证据”（第172行） | **已在 c3f6e9e/8c25b31 补齐**：诊断页新增「升级记录」分区（最近 20 条，含失败原因） | 初版判 B，现判 A |
| D43 标“已实现”（第133行） | **已在 c3f6e9e 补齐**：备份页可设保留份数并二次确认后清理旧自动备份 | 初版判 B，现判 A |
| D19 标“已实现”（第94行） | **已在 2865a90 补齐**：记忆详情每个来源可批量软删（二次确认、回报条数） | 初版判 B，现判 A |
| D47 标“部分实现”（第142行） | **已在 c3f6e9e 补齐**：分项开关 `allowNewConversation` + 会话列表来源标识（她主动开的 / 历史导入） | 初版判 B，现判 A |
| D58 标“部分实现” | **已在 c3f6e9e 补齐**：后台页新增“离线可用 / 离线不可用”清单，明确本地推理未接入 | 初版判 B，现判 A |
| D71 标“部分实现” | **已在 c3f6e9e 补齐**：图片理解支持一次选多张、逐张 OCR/理解、可编辑汇总 | 初版判 B，现判 A |
| D03/D04 标“已实现有证据”（第73、74行） | **已在 d2d11b0 补齐**：日记/反思/自主洞察/主动意图四类结构化任务统一声明 `response_format=json_object`，端点返回 4xx 时自动撤回该字段重试；工具调用仍按决策只做协议与校验（不执行副作用） | 初版判 C，现判 A（D03 属非 UI 项） |

---

## 二、七个入口的实测清单

### 2.1 一级入口（Tab）

| 入口 | 证据 | 说明 |
|---|---|---|
| 聊天 | `Features/Root/RootView.swift:44-50` | 主会话聊天 |
| 记忆 | `RootView.swift:52-56` | 记忆列表与详情 |
| 成长 | `RootView.swift:58-62` | 陪伴统计 + 「她的反思」与手动反思 |
| 空间 | `RootView.swift:64-68` | 日记、关系、附件、主动行为、人格导入 |
| 设置 | `RootView.swift:70-74` | 全部配置与维护页 |

### 2.2 设置页可达页面

| 二级页 | 入口证据 |
|---|---|
| 外观 `AppearanceSettingsView` | `Features/Settings/SettingsView.swift:119-131` |
| 本地模型 `LocalModelsView` | `SettingsView.swift:161-165` |
| 预算与成本 `BudgetCenterView` | `SettingsView.swift:166-170` |
| 待确认事项 `ApprovalCenterView` | `SettingsView.swift:262-279` |
| AstrBot 迁移 `AstrBotImportView` | `SettingsView.swift:269-273` |
| 隐私与安全 `PrivacySettingsView` | `SettingsView.swift:281-313` |
| 备份与恢复 `BackupCenterView` | `SettingsView.swift:288-292` |
| 通知 `NotificationSettingsView` | `SettingsView.swift:293-297` |
| 权限 `PermissionCenterView` | `SettingsView.swift:298-302` |
| 后台与运行方式 `BackgroundSettingsView` | `SettingsView.swift:303-307` |
| 诊断与存储 `DiagnosticsView` | `SettingsView.swift:315-333` |
| 更新日志 `ChangelogView` | `SettingsView.swift:335-341` |
| 反馈与诊断报告 `FeedbackView` | `SettingsView.swift:342-346` |
| 删除全部数据 `DataDeletionView` | `PrivacySettingsView.swift:51-53,198-208` |
| 模型配置编辑 `ModelConfigEditor` | `SettingsView.swift:49-54` |

### 2.3 空间页可达页面

| 二级页 | 入口证据 |
|---|---|
| 日记 `DiaryView` | `Features/Space/SpaceView.swift:165-175` |
| 关系回顾 `RelationshipCenterView` | `SpaceView.swift:176-186` |
| 附件库 `AttachmentLibraryView` | `SpaceView.swift:187-197` |
| 主动行为 `ProactiveView` | `SpaceView.swift:198-208`（**静态占位页**） |
| 导入人格文件 `PersonaImportView` | `SpaceView.swift:209-219` |
| 模型与接口（跳设置 Tab） | `SpaceView.swift:220-230` |

### 2.4 聊天页可达页面与动作

| 页面/动作 | 入口证据 |
|---|---|
| 会话列表 `ConversationListView` | `Features/Chat/ChatView.swift:54-69,177-179` |
| 会话内搜索 | `ChatView.swift:70-77,386-445` |
| 全局搜索 `GlobalSearchView` | `ChatView.swift:86-90,180-184` |
| 消息整理 `MessageOrganizerView` | `ChatView.swift:91-95,185-191` |
| 跳到日期 | `ChatView.swift:96-101,220-243` |
| 删除今天/关键词删除/清空 | `ChatView.swift:102-117,146-165` |
| 外观 `ThemeSettingsSheet` | `ChatView.swift:81-85,166-176` |
| 编辑消息 `EditMessageSheet` | `ChatView.swift:192-199` |
| 语音输入 `VoiceInputSheet` | `ChatView.swift:509-513,200-206` |
| 图片理解 `ImageUnderstandingSheet` | `ChatView.swift:514-518,207-212` |
| 表情面板 `StickerPanelView` | `ChatView.swift:519-523,213-219` |
| 角色在场 `CharacterPresenceView` | `ChatView.swift:292-311` |

### 2.5 记忆页 / 日记页 / 成长页

| 页面 | 证据 | 可达内容 |
|---|---|---|
| 记忆页 | `Features/Memory/MemoryView.swift:29-85` | 列表、搜索、归属筛选、待确认提案、详情 |
| 记忆详情 | `MemoryView.swift:76-84` → `MemoryDetailView.swift:216-256` | 修正、归档、删除、恢复、来源、版本 |
| 日记页 | `Features/Diary/DiaryView.swift:47-107` | 列表、补写卡片、编辑入口 |
| 日记编辑 | `DiaryView.swift:95-106` → `DiaryEditorView.swift:285-355` | 保存、沉淀记忆、人格提案、删除 |
| 成长页 | `Features/Growth/GrowthView.swift` | 陪伴天数/消息统计 + 反思记录列表与「现在反思一次」 |

### 2.6 “文件存在但无入口”的核查

- **无孤立页面文件**：`Features/` 下所有 `*View.swift` 均可在上述导航链中找到引用。
- **有页面但无真实业务**：`Features/Proactive/ProactiveView.swift:1-22` 是静态说明页，没有调用 `ProactiveMessageService`，也没有“主动消息/自主记录”列表。
- **有能力但无任何页面**：
  - 自主度分项控制：`AutonomyService.savePolicy/pause/resetToDefault`（`Packages/DFData/Sources/DFData/AutonomyService.swift:80,124,149`）无 UI。
  - 主动消息治理：`ProactiveMessageService` 无 UI。
  - 核心人格编辑与版本回退：`PersonaGrowthService.versions/restore`（第235、263行）无 UI。
  - 升级记录：`UpgradeRecordService.recent`（第117行）无 UI。
  - 反思/洞察：`MemoryProcessingService.reflect`（第534行）、`AutonomyInsightService`（第15行）无 UI。
  - 工具调用与结构化输出：`DFCore/AI/ToolCall.swift:112`、`DFCore/AI/StructuredOutput.swift:178` 无生产调用点。

---

## 三、D01–D72 逐项矩阵

> 路径均相对仓库根；“无”表示没有页面入口。
> “一句话缺口”只写最重要的一个；A 项写残余边界，B/C 项写补齐方向。

| 编号 | 决策摘要(≤14字) | 状态 | 页面/入口(路径:行) | Service | 一句话缺口 |
|---|---|---|---|---|---|
| D01 | 本地模式尽量全功能 | D | 无 | 无本地推理 | 本地模型决策暂缓（ADR-08），仅保留注册/下载 |
| D02 | 本地上下文长度实测 | D | 无 | 无 | 依赖真机与模型选型，本阶段不投入 |
| D03 | 应用层兼容工具调用 | A | 无（非 UI 项） | `DFCore/AI/ToolCall.swift:112` | 协议/校验/提示词片段已实现并单测；本版不注册工具、不执行副作用（设计边界） |
| D04 | 结构化输出方式不限 | A | 无（非 UI 项） | `StructuredChatRunner.swift`、`DFCore/AI/StructuredOutput.swift:178` | 四类结构化任务声明 `response_format=json_object`，4xx 自动回退到文本提取 |
| D05 | 本地多模态第一版 | D | `ChatView.swift:508-529` → `ImageUnderstandingSheet`/`VoiceInputSheet` | `media` | 云端图片/OCR/ASR 可用；本地推理暂缓 |
| D06 | 人格导入四格式 | A | `SpaceView.swift:209-219`、`SettingsView.swift:269-273` → `PersonaImportView.swift:28-159` | `personaImport` | 需到审批中心二次确认（设计如此） |
| D07 | 外围人格成长与回退 | A | `SettingsView.swift` → `PersonaVersionsView.swift`（历史版本 + 回退） | `personaGrowth.versions/restore` | 回退需二次确认（设计如此） |
| D08 | 手动自动外部加密备份 | A | `SettingsView.swift:288-292` → `BackupCenterView.swift:47-186` | `backupService` | 保留数量不可调 |
| D09 | 每日自动与增量备份 | A | `BackupCenterView.swift:70-84`（列表可见） | `backupScheduler`（`DaFeiYuApp.swift:124`、`BackgroundRefreshService.swift:127`） | 无开关与下次计划展示 |
| D10 | 云端预算与成本控制 | A | `SettingsView.swift:166-170` → `BudgetCenterView.swift:32-111` | `budget` | 无 |
| D11 | 删除会话保留记忆 | A | `ConversationListView.swift:150-159`；`ChatViewModel.swift:663-683` | `conversationAdmin` | 无 |
| D12 | 记忆整理与版本恢复 | A | `MemoryView.swift:29-85` → `MemoryDetailView.swift:216-256` | `memories`、`memoryProcessing` | 合并/整理引擎无独立入口 |
| D13 | 主动通知可切换 | A | `NotificationSettingsView.swift`（策略区） | `autonomy.savePolicy` | 档位/总开关已落库并参与闸门 |
| D14 | 免打扰与频率上限 | A | `NotificationSettingsView.swift`（策略区） | `autonomy.savePolicy` | 免打扰起止/最小间隔/每日上限均可调并落库 |
| D15 | 后台整理与启动补算 | A | 无（启动/后台自动） | `autonomy.backfill`（`BackgroundRefreshService.swift:121-122`） | 纯后台，无记录可查看 |
| D16 | 语音转写跟随模式 | A | `ChatView.swift:509-513` → `VoiceInputSheet.swift:132-144,268-307` | `media`、`privacy` | 云端转写依赖模型配置 |
| D17 | 图片OCR与文字搜索 | A | `ChatView.swift:514-518` → `ImageUnderstandingSheet.swift:134-171` | `media`、`attachmentTexts` | OCR 真机语言支持未验 |
| D18 | 日记触发人格提案 | A | `DiaryEditorView.swift:328-341,428-454` | `DiaryPersonaProposalService` | 无 |
| D19 | 三套记忆与来源批删 | A | `MemoryDetailView.swift`（来源区垃圾桶） | `memories.softDelete(sourceType:sourceID:)` | 已可批量软删并回报条数 |
| D20 | 备份默认加密 | A | `BackupCenterView.swift:49-68,194-198` | `backupService` | 无 |
| D21 | 后台不保证及时说明 | A | `SettingsView.swift:303-307` → `BackgroundSettingsView.swift:9-48` | `BackgroundExecutionPolicy` | 无 |
| D22 | 消息编辑留痕 | A | `ChatView.swift:644-646`；`ChatViewModel.swift:448-476` | `editing` | 无 |
| D23 | 撤回消息并提示 | A | `ChatView.swift:664-668`；`ChatViewModel.swift:478-489` | `editing` | 无 |
| D24 | 逐条批量按条件删除 | A | `ChatView.swift:102-117,146-165` | `deletion` | 无 |
| D25 | 全局搜索四域定位 | A | `ChatView.swift:86-90,180-184` → `GlobalSearchView.swift:29-73` | `unifiedSearch` | 无 |
| D26 | 收藏重要标签整理 | A | `ChatView.swift:91-95,185-191` → `MessageOrganizerView.swift:30-70` | `messageOrganization` | 无 |
| D27 | 附件原图与独立库 | A | `SpaceView.swift:187-197` → `AttachmentLibraryView.swift:16-81` → `AttachmentPreviewView.swift:25-60` | `attachmentReferences` | “下载”依赖系统分享（存储图像） |
| D28 | 语音录制转写重转写 | A | `VoiceInputSheet.swift:34-130,196-266`；`AttachmentLibraryView.swift:220-225` | `media` | 倍速/耳机/后台控制未做（属 D71） |
| D29 | 文件能力分级 | A | `AttachmentLibraryView.swift:243-252` | `FileCapabilityCatalog` | 无 |
| D30 | 核心人格受写保护 | A | `SettingsView.swift` → `PersonaVersionsView.swift`（编辑核心提示词） | `personaGrowth.updateCorePrompt` | 只能由用户主动保存；AI 提案仍被拒（写保护不变） |
| D31 | 关系档案与回顾 | A | `SpaceView.swift:176-186` → `RelationshipCenterView.swift:18-43` | `relationships` | 无 |
| D32 | 自我观察与反思 | A | `GrowthView.swift`（「她的反思」+ 现在反思一次） | `reflections.run`（`ReflectionAutoService`） | 素材不足时不写入，界面如实提示 |
| D33 | 日记双方编辑留版本 | A | `DiaryView.swift:95-106` → `DiaryEditorView.swift:285-355` | `diary` | 无 |
| D34 | 日记第一人称结构化 | A | `DiaryView.swift:281-359`；`DiaryEditorView.swift:205-258` | `diary` | 无 |
| D35 | 日记沉淀长期记忆 | A | `DiaryEditorView.swift:313-326,396-426` | `DiaryMemoryService` | 无 |
| D36 | 表情动作情绪动画 | A | `ChatView.swift:292-311` | `characters`、`characterStates` | 角色形象仍为占位插画 |
| D37 | 情绪推断与表达边界 | A | `ChatView.swift:292-311`；`AppContainer.swift:544-552` | `CharacterStateService`、`EmotionSignal` | 情绪只显示色点，无来源说明 |
| D38 | AstrBot完整迁移 | A | `SettingsView.swift:269-273` → `AstrBotImportView.swift:25-160` | `astrbotImporter` | 无 |
| D39 | 未识别数据待处理区 | A | `AstrBotImportView.swift:107-124` | `astrbotImporter` | 待处理区只读，无人工归类动作 |
| D40 | 迁移校验与回滚 | A | `AstrBotImportView.swift:144-159,217-260` | `astrbotImporter` | 无 |
| D41 | 多位置与外部云盘 | A | `BackupCenterView.swift:105-134,310-368` | `backupService`、`BackupMirrorService` | 厂商 OAuth 未内置（外部限制） |
| D42 | 换机恢复与预览 | A | `BackupCenterView.swift:93-103,294-407` | `backupService` | 换机流程真机未验 |
| D43 | 保留数量与版本保护 | A | `BackupCenterView.swift`（保留份数 + 清理旧备份） | `backupService`、`backups.delete` | 只清理未校验的自动/增量备份，需二次确认 |
| D44 | 敏感数据与备份加密 | A | `BackupCenterView.swift:49-68,194-198` | `backupService`、`backupKeys` | 密钥无独立管理入口 |
| D45 | 删除全部数据清单 | A | `PrivacySettingsView.swift:198-208` → `DataDeletionView.swift:16-86` | `privacy`、`backupKeys` | 无 |
| D46 | 会话全生命周期管理 | A | `ConversationListView.swift:23-164` | `conversationAdmin` | 无 |
| D47 | 手动与AI主动建会话 | A | `ConversationListView.swift`（来源标识）+ `NotificationSettingsView.swift`（允许主动开新会话） | `conversationAdmin`、`autonomy.savePolicy` | 来源标识只区分“她主动开的 / 历史导入” |
| D48 | 通知三档按类型 | A | `NotificationSettingsView.swift`（策略区） | `autonomy.savePolicy` | 档位已落库，重启后仍生效 |
| D49 | 暂停继续与续写 | A | `ChatView.swift:546-562`；`ChatViewModel.swift:237-277` | `ConversationCoordinator` | 暂停仅挂起界面，请求不取消（ADR-10） |
| D50 | 主动消息治理 | A | `ProactiveView.swift`（主动消息分页） | `proactive` | 列表/收藏/不感兴趣/删除/触发原因均已接 |
| D51 | 归档检索与批量归档 | A | `ConversationListView.swift:18-21,180-217` | `conversationAdmin` | 无 |
| D52 | 完整消息状态显示 | A | `ChatView.swift:292-311,674-708` | `ChatTurnPhase` | 无 |
| D53 | 错误原因与诊断导出 | A | `ChatView.swift:139-145`；`DiagnosticsView.swift:28-106` | `ErrorDiagnoser`、`DiagnosticsService` | 无 |
| D54 | 自主发送不绕过闸门 | A | 无（后台闸门） | `AutonomyGate`、`ProactiveIntentRunner` | 纯闸门，无 UI 需求 |
| D55 | 未读数与全部已读 | A | `ChatView.swift:57-67`；`ConversationListView.swift:53-59` | `conversationAdmin` | 无 |
| D56 | 历史分页与日期跳转 | A | `ChatView.swift:220-243,319-321,366-382` | `messages.page` | 无 |
| D57 | 附件引用检查与清理 | A | `SpaceView.swift:187-197` → `AttachmentLibraryView.swift:47-72` | `attachmentReferences` | 无 |
| D58 | 离线能力与恢复说明 | A | `BackgroundSettingsView.swift:69-90`（离线可用/不可用清单） | `BackgroundExecutionPolicy`、`localModels` | 本地离线推理仍暂缓（ADR-08） |
| D59 | 隐私数据流向与导出 | A | `SettingsView.swift:283-287` → `PrivacySettingsView.swift:58-113` | `privacy`、`UserDataExporter` | 无 |
| D60 | 模型下载Wi-Fi与续传 | A | `SettingsView.swift:161-165` → `LocalModelsView.swift:228-282` | `LocalModelDownloader`、`WiFiOnlyNetworkGate` | 无 |
| D61 | 模型独立备份校验 | A | `LocalModelsView.swift:97-183` | `LocalModelBackupService` | 无 |
| D62 | 高度自主验收与记录 | A | `ProactiveView.swift`（自主记录分页） | `autonomy.runs` | 可查看放行/拦截原因与错误 |
| D63 | FaceID与独立密码 | A | `PrivacySettingsView.swift:117-173` | `privacy`、`AppLockController` | Face ID 真机未验 |
| D64 | 首启向导可跳过 | A | `RootView.swift:34-39,91-100` → `OnboardingView.swift:18-63` | `settings` | 无 |
| D65 | 主题外观与恢复默认 | A | `SettingsView.swift:119-131` → `AppearanceSettingsView.swift:17-61` | `chatTheme` | 无 |
| D66 | 存储分类与空间预警 | A | `SettingsView.swift:315-333` → `DiagnosticsView.swift:54-82` | `diagnostics` | 无 |
| D67 | 升级检查备份与记录 | A | `DiagnosticsView.swift`（升级记录分区） | `upgrades.recent`（`UpgradeRecordService`） | 只记录版本与失败原因，不含正文 |
| D68 | 自主度分项控制 | A | `NotificationSettingsView.swift`（分项开关 + 暂停/恢复/恢复默认） | `autonomy.savePolicy/pause/resume/resetToDefault` | 五个分项开关与运行控制均已落库 |
| D69 | 权限按需申请 | A | `SettingsView.swift:298-302` → `PermissionCenterView.swift:24-48` | `PermissionAdvisor` | 无 |
| D70 | 版本日志反馈诊断 | A | `SettingsView.swift:335-356` → `ChangelogView.swift:15-35`、`FeedbackView.swift:32-82` | `DiagnosticsService`、`FeedbackReportBuilder` | 无 |
| D71 | 语音图片多模态 | A | `ChatView.swift:508-529` → `ImageUnderstandingSheet.swift`（多选逐张分析） | `media` | 倍速/后台播放未做（归 D28） |
| D72 | 多设备恢复与时区 | A | `BackupCenterView.swift:157-172,385-407` | `backupService` | 换机真机未验；语言时区无 UI |

---

## 四、状态 B / C 清单与补齐建议

### 4.1 优先级总表（按“价值/成本”排序）

| 优先级 | 编号 | 状态 | 最小补齐动作（1 句） | 可复用组件 |
|---|---|---|---|---|
| P0 | D48 | ✅ 已完成 | 通知档位改为读写 `AutonomyPolicy.notificationLevel` 并持久化。 | `NotificationSettingsView` 现有表单 |
| P0 | D19 | ✅ 已完成 | 在记忆页加“按来源批量删除”，调用现有 `softDelete(sourceType:sourceID:)`。 | `MemoryView` 顶部菜单、`MemoryDetailView` |
| P1 | D68 | ✅ 已完成 | 新建“自主与通知”页，包含主动聊天/整理/日记/反思/成长分项开关与暂停/恢复默认。 | `SettingsView` 分区、`BudgetCenterView` 表单、`AutonomyService` |
| P1 | D14 | ✅ 已完成 | 在同一页加免打扰时段、最小间隔、每日上限三组输入。 | 同上 |
| P1 | D13 | ✅ 已完成 | 在同一页加“主动通知总开关 + 仅重要”开关，写入策略。 | 同上 |
| P1 | D50 | ✅ 已完成 | 把 `ProactiveView` 改为真实治理列表：删除/收藏/不感兴趣/触发原因/关联记忆。 | `ProactiveView`、`ApprovalCenterView` 列表风格、`ProactiveMessageService` |
| P2 | D62 | ✅ 已完成 | 在主动行为页加“自主记录”区，展示 `autonomy.runs` 的放行/拦截原因。 | `ProactiveView`、`DiagnosticsView` 列表 |
| P2 | D07 | ✅ 已完成 | 在设置页接 `PersonaVersionsView`，展示 `versions` 并支持 `restore`。 | `PersonaVersionsView`、`PersonaGrowthService` |
| P2 | D30 | ✅ 已完成 | 设置页人格区加编辑入口与版本列表；核心人格仅允许用户显式保存。 | `PersonaVersionsView`、`updateCorePrompt` |
| P2 | D43 | ✅ 已完成 | 备份页加“保留份数”步进器与旧备份清理（二次确认）。 | `BackupCenterView` 表单 |
| P3 | D67 | ✅ 已完成 | 在诊断页加“升级记录”区，读取 `UpgradeRecordService.recent`。 | `DiagnosticsView` 分区 |
| P3 | D47 | ✅ 已完成 | 自主页加“允许 AI 主动开新会话”开关，并在会话列表标注来源。 | `NotificationSettingsView`、`ConversationListView` |
| P3 | D58 | ✅ 已完成 | 在后台与运行方式页加“当前离线可用/不可用”清单，明确本地推理未接入。 | `BackgroundSettingsView` |
| P3 | D71 | ✅ 已完成 | 图片理解改为多选（`PhotosPicker` 多选）并逐张分析后汇总。 | `ImageUnderstandingSheet` |
| P4 | D32 | ✅ 已完成 | 在成长页加“她的反思”区，并提供“现在反思一次”按钮触发反思。 | `GrowthView`、`ReflectionAutoService` |
| P4 | D03 | ✅ 已完成 | 决策为“协议+校验，执行由调用方决定”，本版不注册工具，按边界保留。 | `ToolCall.swift` 及其单测 |
| P4 | D04 | ✅ 已完成 | 四类严格 JSON 任务声明 `response_format`，4xx 自动回退文本提取。 | `StructuredChatRunner`、`DiaryAutoService` |

### 4.2 状态 C 的完整清单（0 项）

无。

### 4.3 状态 B 的完整清单（0 项）

无。

### 4.4 状态 D 的完整清单（3 项）

`D01、D02、D05`：均为本地推理/本地模型相关的阶段性暂缓（ADR-08），不是 UI 接入缺陷；D05 的云端图片理解、设备端 OCR/ASR 已可用。

---

## 五、本会话新增能力的接入状态（如实）

> 统一验证口径：**代码核对 + 已完成的 CI 验证**。当前事实：分支 `p1.5/b1` 的 `d2d11b0` 上 `core-tests` 通过、`app-build-check` 的正式版与实验版均编译成功；`build-ipa` 仍排队（macOS runner 容量紧张），**IPA 未产出**；**真机 0 项**。

### 5.1 记忆管理页

| 项 | 结论 |
|---|---|
| 页面 | `Features/Memory/MemoryView.swift:29-85`；详情 `MemoryDetailView.swift:30-81` |
| 入口 | `RootView.swift:52-56`（记忆 Tab）；列表卡片 `MemoryView.swift:99-112` |
| 真实调用 | `container.memories.memories/search`（`MemoryView.swift:260-285`）；提案确认 `container.pendingMemoryProposals/approveMemoryProposal`（第287-305行）；详情修正/归档/删除/恢复 `container.memories`（`MemoryDetailView.swift:268-329`） |
| 持久化 | `memories` / `memory_versions` / `memory_sources`，真实读写 |
| 状态 | **A（统计口径）**：有加载、错误、空态、操作反馈 |
| 验证到哪一步 | 静态代码；单测 `MemoryRepositoryTests`、`MemoryProcessingServiceTests` 已存在并通过 d2d11b0 的 core-tests；App 编译已通过（d2d11b0）；IPA 与真机未验证 |

### 5.2 日记自动生成入口

| 项 | 结论 |
|---|---|
| 页面 | `Features/Diary/DiaryView.swift:47-107` |
| 入口 | `SpaceView.swift:165-175` → 日记页；补写按钮 `DiaryView.swift:214-231` |
| 真实调用 | `container.diary.entries`（`DiaryView.swift:111-127`）；`container.runDiaryCompensation`（第129-144行）；实现见 `AppContainer.swift:366-388` |
| 23:00 策略 | 文案说明在 `DiaryView.swift:173`；调度 `DiarySchedulePolicy` + `BackgroundRefreshService.swift:67-97`（`earliestBeginDate` 23:00，系统不保证准点） |
| 持久化 | `diary_entries`，生成结果落库；已有日记/用户编辑会跳过 |
| 状态 | **A（统计口径）**：有加载、空态、错误、补写结果反馈 |
| 验证到哪一步 | 静态代码；`DiarySchedulePolicyTests`、`DiaryAutoServiceTests` 已在 d2d11b0 的 core-tests 中通过；App 编译已通过（d2d11b0）；IPA 与真机未验证 |

### 5.3 表情面板

| 项 | 结论 |
|---|---|
| 页面 | `Features/Sticker/StickerPanelView.swift:38-113` |
| 入口 | 聊天输入栏“+”菜单 `ChatView.swift:508-529`（第519-523行为表情入口） |
| 真实调用 | `container.stickers.recent/favorites/stickers`（`StickerPanelView.swift:142-164`）；选中后 `ChatViewModel.sendSticker`（`ChatViewModel.swift:389-427`）写入消息并 `recordUsage` |
| 持久化 | `stickers` / 使用记录 / `messages`，真实落库 |
| 状态 | **B→A 的边界**：Emoji 表情可真实发送；静态图/GIF 只展示不发送（`StickerPanelView.swift:4-9` 已如实标注），在线表情库未接 |
| 验证到哪一步 | 静态代码；`StickerRepositoryTests` 已在 d2d11b0 的 core-tests 中通过；App 编译已通过（d2d11b0）；IPA 与真机未验证 |

### 5.4 时间上下文与召回

| 项 | 结论 |
|---|---|
| 页面 | 无独立 UI（设计如此） |
| 入口 | 聊天编排器注入：`AppContainer.swift:531`（当前时间）、`AppContainer.swift:533-540`（记忆召回） |
| 真实调用 | `CurrentTimeContext.describe`（`AppContainer.swift:576-578`）；`RecallContextBuilder.recall`（`AppContainer.swift:475,533-540`） |
| 持久化 | 时间不落库；召回读取 `memories` / `diary_entries` / 历史消息 |
| 状态 | **A（后台注入类）**：已接入真实聊天链路，无独立 UI 属正常 |
| 验证到哪一步 | 静态代码；`CurrentTimeContextTests`、`RecallContextBuilderTests` 已在 d2d11b0 的 core-tests 中通过；App 编译已通过（d2d11b0）；IPA 与真机未验证 |

### 5.5 本会话新增能力的统一说明

- 以上四项均能在代码层追到“页面/入口 → ViewModel/Service → 持久化”的完整链路。
- 验证进度统一为：**已过 core-tests**、**已过 App Target 编译（正式版 + 实验版，不签名）**；**IPA 未产出**（runner 未分配）；**真机未验收**。
- 因此这四项只能标注到"已实现 / 已持久化 / 已接入聊天 / 已接入 UI / 已过自动化测试 / 已过 App 编译"，**不得**标注"已过 IPA"或"已过真机"。

### 5.6 本轮补齐项的逐项证据（c3f6e9e / 8c25b31 / d2d11b0）

| 项 | 页面/入口 | 真实调用 | 持久化 | 状态 | 验证到哪一步 |
|---|---|---|---|---|---|
| 记忆自检（诊断页） | `DiagnosticsView.swift`「记忆链路自检」、`MemoryHealthService` | `memoryHealth.check/repairIndex` | 只读统计；修复只补/清 `memory_fts`，不改正文 | A | 单测 `MemoryHealthServiceTests`（6 例）通过 d2d11b0 core-tests；App 编译通过；IPA/真机未验 |
| 核心人格编辑与回退 | `SettingsView` → `PersonaVersionsView` | `personaGrowth.updateCorePrompt/versions/restore` | `persona_items` + `persona_versions` | A | 单测 `PersonaGrowthServiceTests`（新增 4 例）通过；App 编译通过 |
| 自我反思 | `GrowthView`「她的反思」+ 现在反思一次 | `reflections.run`（`ReflectionAutoService`） | `reflections`，结论必须引用真实记忆 ID | A | 依赖真实模型调用，尚无单测；App 编译通过；真机未验 |
| 备份保留与清理 | `BackupCenterView` 保留份数 + 清理旧备份 | `backups.delete` | `settings["backup.retention.count"]` | A | 依赖既有 `BackupServiceTests`；App 编译通过 |
| 会话来源标识 | `ConversationListView` 标题旁胶囊 | `conversationAdmin` 读取 `kind` | 无新增表 | A | App 编译通过；真机未验 |
| 升级记录 | `DiagnosticsView`「升级记录」 | `upgrades.recent` | 读 `upgrade_records` | A | 单测 `UpgradeRecordServiceTests`（6 例）通过；App 编译通过 |
| 离线清单 | `BackgroundSettingsView` | 纯说明，无伪造开关 | 无 | A | App 编译通过；真机未验 |
| 多图理解 | `ImageUnderstandingSheet`（`PhotosPicker` 多选） | `media.ingest` + OCR + `imageAnalyses` | `attachments` / `image_analyses` | A | App 编译通过；真实 OCR 语言支持真机未验 |
| 结构化输出 JSON 模式 | 无 UI（内部任务） | `StructuredChatRunner`（日记/反思/洞察/意图 4 处） | 不新增表 | A | 单测 `StructuredChatRunnerTests`（4 例）通过；App 编译通过 |

> 备注：反思与多图理解依赖真实模型/系统能力，本机无法离线验证运行结果，只能证明编译与静态链路完整；不得据此标注“已过真机”。

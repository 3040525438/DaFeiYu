# DaFeiYu V2.0 需求追溯矩阵与任务分解

> 性质：**覆盖率审查基线**。回答"72 项正式决策 + 后续补充需求，各自由哪个任务承载、当前做到哪一步、证据在哪"。
> 依据：72 项正式产品决策（《DaFeiYu_V2.0_项目总报告.md》第二章）、最终授权书（2026-11-15）、历史需求文档（193+84 条）、当前仓库实际代码。
> 更新规则：只追加结论、不回改历史结论；状态变化用"审查批次"列记录。
> 证据等级：**E0** 无证据 / **E1** 代码存在 / **E2** 单测覆盖 / **E3** CI 通过 / **E4** 真机验收。状态必须标注到具体等级，不得跳级。

---

## 一、审查口径

### 1.1 状态定义（互斥，取最高证据）

| 状态 | 含义 | 判定标准 |
|---|---|---|
| 已实现有证据 | 代码 + 单测（+CI/真机）齐全 | 至少 E2，关键路径 E3 |
| 已实现待验证 | 代码已合并但本批次 CI 未出结果 | E1，CI 进行中 |
| 部分实现 | 结构/字段/骨架存在，业务闭环缺失 | E1 且闭环缺失 |
| 正在开发 | 本批次正在写代码 | — |
| 尚未开发 | 无对应代码 | E0 |
| 技术阻塞 | 受环境/平台/外部数据限制无法推进 | E0 + 阻塞原因 |
| 需要用户确认 | 产品口径未定或涉及不可逆操作 | — |

### 1.2 本轮审查的事实基线

| 项 | 值 |
|---|---|
| 仓库 | `github.com/3040525438/DaFeiYu`，分支 `p1.5/b1` |
| 最新提交 | `285269c` feat(v2-m4) v4_persona 迁移 |
| 迁移版本 | v1_phase1 / v2_memory / v3_chat / **v4_persona（本批次新增）** |
| 单测规模 | 225（v3 基线）+ 本轮新增 16（V4 10 项 + 指纹 6 项） |
| 唯一测试通道 | GitHub Actions `core-tests.yml`（DFCore/DFAI/DFData 三包） |
| 唯一产物通道 | `build-ipa.yml`（macos-15，未签名 IPA） |
| 本地能力 | 无 swift、无 Xcode（Windows），无法本地编译/跑测 |
| 本批次 CI | `core-tests` run 于 `285269c` **进行中**，尚未出结论 |

> 事实边界：本文档中"已实现待验证"一律不代表通过；"CI 通过"单独由 Actions 结论支撑，不与其他状态混用。

---

## 二、13 个重点领域的覆盖结论（对应审查要求第 3 条）

| # | 领域 | 当前覆盖 | 结论 |
|---|---|---|---|
| 1 | 聊天 UI 及全部消息交互 | 单会话收发、失败徽标、取消、引用、分页 | **部分**：编辑/撤回/收藏/多气泡/思考态/未读均缺 |
| 2 | 多会话与统一记忆 | `conversations` 表 + `ensureMainConversation` | **部分**：置顶/归档/排序/未读/主动建会话缺 |
| 3 | 图片理解、OCR、多图分析 | 仅 `attachments` 元数据表 | **未开发** |
| 4 | 语音输入与完整播放控制 | 无 | **未开发** |
| 5 | 本地模型下载/导入/管理/离线运行 | 无（仅云端 OpenAI 兼容 + Keychain） | **未开发 + 阻塞**（依赖设备实测与模型选型） |
| 6 | 高度自主陪伴与主动联系 | `proactive_intents/messages` 空表结构 | **部分（仅结构）** |
| 7 | 核心人格保护与外围成长 | tier 分层、`growth_enabled`、指纹基线、版本表 | **部分**：成长提案与回退流程缺 |
| 8 | 每日日记 | 无 `diary_entries` | **未开发** |
| 9 | Face ID、隐私、安全、数据删除 | 无 | **未开发** |
| 10 | AstrBot 完整迁移与原始数据保护 | 已完成独立数据复核（83MB/833 文件/17183 聊天/5121 记忆），迁移代码未写 | **部分**：复核完成，迁移未开发 |
| 11 | L1–L7 记忆加工与三主体记忆 | 三套 scope + 七层表结构全部就位（v2），FTS 回填完成 | **部分**：抽取/融合/反思引擎缺 |
| 12 | 备份恢复 | 无 `backup_manifests/restore_logs` | **未开发**（v7 规划） |
| 13 | App/UI/集成/真机测试 + CI/IPA | App 层 22 个 Swift 文件、0 个 App 层测试；CI 三包测试通过；IPA 工作流就绪 | **部分**：真机验收未执行 |

**结论：现有 10 项宽泛待办不足以承载 72 项决策，必须拆到"工作包 → 子任务"两级，且每个子任务绑定验收标准。**

---

## 三、72 项正式决策逐条追溯

> 状态列取最高证据等级；证据路径相对仓库根；提交号指该能力所在批次。

### 3.1 第一轮（D01–D12）：模型、人格、数据

| 编号 | 决策摘要 | 状态 | 代码证据 | 测试证据 | 承载任务 |
|---|---|---|---|---|---|
| D01 | 纯本地模式尽可能支持全部核心功能，遵守 iOS 限制 | **暂缓（本地模型决策，ADR-08）** | 无本地推理层；本地模型注册表/迁移/接口保留不删 | — | W5-1（本阶段不投入，不计完成） |
| D02 | 本地模型上下文长度由实测决定 | **暂缓（本地模型决策，ADR-08）** | — | — | W5-2（需真机，本阶段不投入） |
| D03 | 不要求模型原生工具调用，应用层兼容 | 已实现有证据 | `DFCore/AI/ToolCall.swift`：`ToolDefinition`（必需/可选参数与类型）+ `ToolCallProtocol.parse`（```tool 代码块信封、name/tool 别名、未知工具拒绝、缺少必需参数拒绝、未声明参数拒绝、参数类型校验）+ `promptFragment`（无工具时返回空串，不污染提示词）；不执行任何副作用，由调用方按 `ToolInvocation` 决定 | `ToolCallTests`(14)，run 43714304218 | W5-4（`a4a1f1e`） |
| D04 | 结构化输出实现方式不限定 | 已实现有证据 | `DFCore/AI/StructuredOutput.swift`：`JSONValue` 强类型 + `extractObject`（容忍代码块/前后说明/字符串内花括号/转义引号，未闭合返回 nil）+ `StructuredSchema`（必需/可选字段、类型、未声明字段）+ `parse(_:schema:)`；`ChatRequest.responseFormat` + `OpenAIWireCodec` 仅在声明时发送 `response_format`（Provider 不支持时仍可走文本提取） | `StructuredOutputTests`(17)、`ProviderRequestBodyTests`(4)，run 43714304218 | W5-4（`d0a8f5b`/`a4a1f1e`） |
| D05 | 本地多模态第一版：文字/图片理解/ASR；不做 TTS | 部分实现（本地推理部分暂缓，ADR-08） | 端上 ASR（`SpeechTranscriber`）、Vision OCR、云端视觉通道（`ImageUnderstandingSheet`、`ChatImage`）；本地推理未做且本阶段不投入 | `ChatTurnImageTests`(4) | W4-1、W5-3（本地部分依赖 N-18，暂缓） |
| D06 | 人格导入支持 AstrBot/JSON/MD/TXT | 已实现 | `persona_imports` 表 + `AstrBotImporter`；`PersonaFileParser`（JSON/MD/TXT，去重/截断/代码块跳过）+ `PersonaFileImportService`（只生成待审批提案，核心人格不受影响）+ `PersonaImportView` | `PersonaFileParserTests`(12)、`PersonaFileImportServiceTests`(6) | W6-4（完成） |
| D07 | 外围人格可成长，留版本/查看/回退；核心不可自动改写 | 已实现 | `PersonaGrowthService`（提案/审批/版本/回退/指纹）+ `ApprovalCenterView` | `PersonaGrowthServiceTests`(9) | W6-2、W6-3（已完成） |
| D08 | 手动/自动/外部加密备份 + 保存位置 + 保留数量 | 已实现 | `BackupService.createBackup`（加密/明文双通道、保留策略）+ `BackupCenterView` 导出/复制到外部目录/从文件导入 + `BackupScheduleService` 自动调度 | `BackupServiceTests`(12)、`BackupCryptoTests`(8)、`BackupScheduleTests`(9) | W9-2（完成） |
| D09 | 每日自动备份 + 重要变更增量备份 | 已实现 | `BackupSchedulePolicy`（每日一次完整、变更后增量、最小间隔）+ `BackupScheduleService`（空库不备份、失败不推进时间戳），接入启动与后台唤醒 | `BackupScheduleTests`(9) | W9-2（调度完成） |
| D10 | 云端预算/提醒/暂停/单次成本估算 | 已实现（数据层 + App 接线） | `DFCore/Budget/Budget.swift`（`CostKind`/`ModelPricing`/`TokenEstimator`/`BudgetGuard`）、`DFData/BudgetService.swift`（事务内预占 + 结算/失败/取消/审计）、`V13CostLedger.swift`（`cost_ledger`）、`AutonomyGate` 预算上下文、`ChatOrchestratorImpl` 预占/结算、Provider `stream_options.include_usage`、`BudgetCenterView` | `BudgetTests`(13)、`BudgetServiceTests`(12)、`MigrationV13Tests`(3)、`ChatOrchestratorBudgetTests`(4) | W5-5（完成） |
| D11 | 删除会话默认保留记忆 | 已实现 | `GRDBConversationAdminRepository.delete/deleteBatch`（只删消息与索引，不碰 memories） | `ConversationAdminTests`(13) | W3-4（已完成） |
| D12 | 记忆整理/合并/纠错 + 来源/版本/恢复；重要修改需确认 | 已实现 | `memory_versions`、`memory_links`、`memory_sources`、`memory_importance_history`、`MemoryProcessingService.consolidate/reflect`、`MemoryConflictDetector` | `MigrationV2Tests`、`MemoryProcessingTests`(19)、`MemoryProcessingServiceTests`(13) | W8-2、W8-5（已完成） |

### 3.2 第二轮（D13–D21）：主动行为、多模态、记忆、备份

| 编号 | 决策摘要 | 状态 | 代码证据 | 测试证据 | 承载任务 |
|---|---|---|---|---|---|
| D13 | 主动消息通知可切换，默认仅重要 | 已实现（数据层） | `NotificationLevel` + `NotificationTiering` + `proactive_messages.notify_level` | `testNotificationTiering` | W7-3、W7-4 |
| D14 | 勿扰 23:00–08:00、最小间隔 2h、每日上限 5，可调 | 已实现 | `AutonomyPolicy` 默认值 + `AutonomyGate` | `AutonomyGateTests` + `AutonomyServiceTests` 六项闸门用例 | W7-3 |
| D15 | 一天未开 App 后台整理；失败下次启动补算；不私换模型 | 已实现（数据层） | `AutonomyService.backfill` + `AutonomyBackfill` | `testBackfillCreatesMissingDailyTasks`、`testBackfillReportsOverdueAndExpiresStale` | W7-5 |
| D16 | 语音转文字跟随当前运行模式；上传需授权 | 部分实现（策略与文案完成；当前仅设备端转写，云端路径未接入） | `SpeechInputPolicy`：设备端/云端/不可用三态，云端必须显式授权，未授权或拒绝一律不启动并给文字兜底；语音页明确"设备端转写、音频不会上传"（`f62aca2`） | `SpeechInputPolicyTests`(7) | W4-4、W9G |
| D17 | 图片 OCR + 文字搜索，优先设备端 | 已实现 | Vision OCR（`MediaProcessing`）+ `attachment_texts` FTS + `ImageUnderstandingSheet` | `MultimodalTests`(14)（OCR 真机待验） | W4-2（已完成） |
| D18 | 日记可触发外围人格成长提案，重要需确认 | 已实现 | `DiaryPersonaProposalService`（观察/关系变化 → 待审批提案，正文与感受不直接变人格，证据含日记 id 与原文，重复即跳过）+ 日记编辑页入口 | `DiaryPersonaProposalServiceTests`(5) | W6-5（完成） |
| D19 | 单条/分类/三套记忆管理 + 按来源批量删除 | 已实现 | `memory_scopes`、`v_memory_*`、`GRDBMemoryRepository.softDelete(sourceType:sourceID:)`、`MemoryProcessingService` | `MigrationV2Tests.testT09`、`MemoryRepositoryTests`(11) | W8-5、W8-6（已完成） |
| D20 | 备份默认加密；明文导出需二次确认 + 风险提示 | 已实现 | `BackupService.createBackup(encrypted: true 默认)` + `BackupContainer` + `BackupCenterView` 风险提示 | `BackupCryptoTests`(8)、`BackupServiceTests`(8) | W9-2（已完成） |
| D21 | iOS 后台不保证及时；远程调度需单独说明成本/隐私 | 已实现有证据（App 编译待手动触发） | `BackgroundExecutionPolicy`（timingGuaranteed 恒 false、后台做什么、成本计入预算、只发最少上下文、下次任务的非承诺式说明）+ 设置页「后台与运行方式」说明页（`f62aca2`） | `BackgroundExecutionDisclosureTests`(5) | W7-5、W9G |

### 3.3 第三轮（D22–D29）：聊天与附件管理

| 编号 | 决策摘要 | 状态 | 代码证据 | 测试证据 | 承载任务 |
|---|---|---|---|---|---|
| D22 | 消息可编辑并保留编辑记录 | 已实现 | `GRDBChatInteractionRepository.editMessage` + `messages.edit_count` + 版本表 | `ChatInteractionTests`(13) | W2-3（已完成） |
| D23 | 可撤回自己的消息并显示提示 | 已实现 | `revokeMessage` + `messages.revoked_at/revoke_reason` | `ChatInteractionTests`(13) | W2-3（已完成） |
| D24 | 逐条/批量/按日期关键词筛选删除/清空会话 | 已实现 | 软删 + 范围删除 + 关键词删除 + 清空会话（`ChatInteractions.swift`） | `ChatInteractionTests`(13) | W2-4（已完成） |
| D25 | 全局搜索聊天/记忆/日记/附件文字并定位原文 | 已实现有证据（数据层 + App 界面） | 数据层 `GRDBUnifiedSearchRepository`（`4cff077`）：四域统一检索，命中带定位信息（`conversationID`/`messageID`/`diaryDate`）+ 原文摘要 `SearchSnippet`；归档会话仍可检索；App 层 `GlobalSearchView`/`GlobalSearchViewModel`（`310a940`）：四域分组、范围开关、空结果/异常提示、消息命中经 `ChatViewModel.openGlobalSearchHit` 切会话并滚动定位、记忆/日记打开只读详情 | `UnifiedSearchTests`(10)、`SearchSnippetTests`(8)，run 43697137498；App 编译待手动触发 `app-build-check` | W2-5 数据层 + W6 界面（`310a940`）。缺口：附件命中无关联消息时只显示片段，不提供原图预览 |
| D26 | 收藏/重要标记/分类整理；收藏不自动成记忆 | 已实现有证据（数据层 + App 界面） | `v14_message_organization`（`messages.is_important/important_at` + `message_tags`）+ `GRDBMessageOrganizationRepository`（批量收藏/重要/标签，单事务，标签归一化去重）；App 层 `MessageOrganizerView`/`MessageOrganizerViewModel`（`310a940`）：收藏/重要/标签筛选、批量收藏与取消、重要标记与取消、标签增删与结果反馈；**不写 memories/persona** | `MessageOrganizationTests`(13)、`MigrationV14Tests`(4)，run 43697137498；App 编译待手动触发 `app-build-check` | W2-5 数据层 + W6 界面（`310a940`）。缺口：标签不支持全局重命名（数据层无该能力），只能逐条移除后重加 |
| D27 | 图片原图+缩略图、查看/放大/下载/分享、独立附件库 | 已实现有证据（数据层 + 界面；App 编译待手动触发） | `AttachmentStore.fileURL(forRelativePath:)`；`AttachmentReferenceService.record(id:)`（`effa97f`）；附件库真实缩略图（异步 120pt）、点击原图预览、右键分享文件；新增 `AttachmentPreviewView`：原图查看、双指缩放、双击放大、拖动平移、还原、系统分享，文件缺失如实提示，无网络请求；全局搜索附件命中右键「查看原图」 | `AttachmentReferenceServiceTests` 新增 3 项、`AttachmentLibraryItemTests` | W4-5 + W8B（`effa97f`） |
| D28 | 语音录制/播放/转写/重转写/复制/关联/保留原始音频 | 已实现有证据（App 编译待手动触发） | `VoiceRecorder` + `AudioPreviewPlayer` + `VoiceInputSheet`（录制/播放/设备端转写/回填，明确"音频不上传"）；填入时把附件 id 交给聊天页，`turnOpened` 时挂到该条用户消息（`AttachmentIngestService.link`）；附件库对音频/视频提供「重新转写」「复制转写文本」，重转写覆盖同一行（`f3f7261`） | `MultimodalTests.testAudioAttachmentLinksToMessageWithTranscript`；真机转写依赖设备端中文识别支持 | W4-4、W9F |
| D29 | 常见文件类型；区分保存/预览/读取/理解能力 | 已实现有证据（App 编译待手动触发） | `FileCapabilityCatalog`：图片（保存/预览/OCR/理解）、音频（保存/播放/转写）、视频（保存/播放，不抽帧）、文本（保存/预览/读取/理解）、PDF（保存/预览，不声称可读）、压缩包与未知（仅保存）+ MIME 兜底；附件库列表展示能力摘要（`8577e64`） | `FileCapabilityCatalogTests`(10) | W4-6、W9E |

### 3.4 第四轮（D30–D37）：人格、关系、日记、角色

| 编号 | 决策摘要 | 状态 | 代码证据 | 测试证据 | 承载任务 |
|---|---|---|---|---|---|
| D30 | 核心人格只用户改；AI 仅建议；留版本与回退 | 已实现 | `PersonaGrowthService`（核心写保护 + 提案 + 版本回退）+ `ApprovalCenterView` | `PersonaGrowthServiceTests`(9) | W6-1、W6-3（已完成） |
| D31 | 自主记录关系阶段/共同经历/重要转折，可回顾 | 已实现 | `RelationshipService`（阶段提案→确认、历史、里程碑）+ 审批中心 + 关系回顾页五类独立视图（概览/阶段历程/共同经历/重要转折/纪念日，`RelationshipOverview` 统一分组、排序、精度文案） | `RelationshipServiceTests`(11)、`RelationshipOverviewTests`(13)，commit `78680b6` | W6-6、W9P（已完成） |
| D32 | AI 自身观察/兴趣/观点/经历总结，连续成长记录 | 已实现 | `MemoryProcessingService.reflect` + `ReflectionPolicy` + `reflections` 表 + self 记忆沉淀 | `MemoryProcessingServiceTests.testReflectStoresReflectionsAndDepositsSelfMemory` | W8-4（已完成） |
| D33 | 用户与 AI 都可编辑日记；留版本；AI 修订需确认 | 已实现 | `Diary.swift`（`generatedBy`/`isUserEdited`/`memoryID`/全量版本表）+ `GRDBDiaryRepository` | `DiaryTests`(13) | W6-7（已完成） |
| D34 | 日记第一人称记录共同经历/观察/感受/关系变化 | 已实现 | `V12DiaryStructure.swift`（`shared_experience`/`observation`/`feeling`/`relationship_change` + 确认标记，版本快照同步扩列）+ `Features/Diary/*` 列表与编辑界面 | `MigrationV12Tests`(9)、`DiaryTests`(13)，run `43680552034` | W6-7（已完成） |
| D35 | 日记可成为长期记忆来源，重要变更需确认 | 已实现（自动沉淀） | `DiaryMemoryService.distill`：正文首段→情景候选→证据逐字筛查→写记忆/提案→回填 `memory_id`；已沉淀不重复 | `DiaryTests`(13)、`DiaryMemoryServiceTests`(5) | W6-7、W8-2（`87e19b9`） |
| D36 | 动态表情/动作/情绪/互动动画，分阶段交付 | 已实现有证据（界面渲染未接） | `CharacterMood`（与 `character_states.mood_code` 对齐，未知值回落 neutral，可由 D37 `EmotionKind` 映射）+ `CharacterAction`/`CharacterAnimation`（时长/次数/缩放/幅度全部夹取，支持减弱动态效果）+ `CharacterPresentationPolicy`（精力 <0.25 入休息、高唤醒挥手、焦虑思考、低唤醒静立、亲和 <0.3 幅度减半、无随机确定性输出）+ `InteractionAnimationPolicy`（`ChatTurnPhase` 七态一一对应，进行中/待机循环、终态 ≤0.5s）+ `CharacterStateService`（默认态、单事务更新、状态历史留痕、幂等、空原因拒绝、越界夹取、可由 `EmotionState` 更新） | `CharacterPresentationTests`(15)、`CharacterStateServiceTests`(10)，run 43723798853 | W6-8、W9M（`cc7f91b`） |
| D37 | 情绪/异议/拒绝/幽默；区分真实互动、推断、想象 | 已实现有证据（情绪状态数据源未接） | `DFCore/Persona/SelfExpression.swift`：`EpistemicStance`（observed/inferred/imagined，未知值按推断）+ `EpistemicDisclosure`（事实断言词只能用于真实、想象必须带框架词）+ `ExpressionStance`/`ExpressionPolicy`（拒绝须给理由、异议须说清分歧、幽默禁侮辱、任何态度禁情感施压）+ `EmotionState`（强度夹取 0–1、分档、语气引导）+ `SelfExpressionProtocol.systemFragment` 已接进 `ChatOrchestratorImpl` 每次请求的 system prompt；`memories.epistemic_status` 沿用三态取值 | `SelfExpressionTests`(18)，run 43714304218 | W6-9、W8-3（`ddadfdc`） |

### 3.5 第五轮（D38–D45）：迁移、备份、恢复、数据安全

| 编号 | 决策摘要 | 状态 | 代码证据 | 测试证据 | 承载任务 |
|---|---|---|---|---|---|
| D38 | AstrBot 完整迁移 + 自动分类/去重/关联/质检 + 报告 | 已实现 | `AstrBotImporter`（聊天/记忆/日记/人格/信件/读书笔记/关系账本）+ `AstrBotImportReport` + `AstrBotImportView` | `AstrBotImporterTests`(7) | W9-5（已完成） |
| D39 | 无法识别数据进待处理区，禁止静默丢弃 | 已实现 | `astrbot_import_pending` + 15 类原因码 + 覆盖校验（`coverageProblems`） | `AstrBotImporterTests`(7) | W9-6（已完成） |
| D40 | 迁移前后数量/记录/附件/时间/关联/完整性校验 + 回滚 | 已实现 | 源文件 SHA256 前后比对 + `astrbot_id_map` 精准回滚 + `legacyFingerprint` 校验 | `AstrBotImporterTests`(7) | W9-6（已完成） |
| D41 | 本地/手动导出/授权外部云盘/多位置备份 | 部分实现 | 本地备份 + 导出加密容器（`fileExporter`）+ 授权外部目录（安全作用域书签，可选 iCloud Drive / 第三方网盘在「文件」中的位置）复制备份；厂商 OAuth SDK 仍在缺口 | `BackupServiceTests`(8)，commit `100c85d` | W9-2（导出/外部目录完成） |
| D42 | 换机与重装恢复、范围选择、预览、兼容、空间检查 | 已实现（数据层） | `BackupService.importBackupFile`（加密容器/明文导入、密钥与未知表校验）+ `previewRestore` + 单事务恢复 + 自动安全备份 + `BackupCenterView` 从文件导入；真机换机流程待验 | `BackupServiceTests`(12) | W9-3（真机待验收） |
| D43 | 保留数量、重要版本保护、按时间/版本/类型管理 | 已实现 | `BackupService` 保留策略（`keepCount`、重要版本不清理） | `BackupServiceTests`(8) | W9-2（已完成） |
| D44 | 本地敏感数据加密、备份默认加密、用户控密钥、数据流向 | 已实现 | `BackupContainer`（AES-256-GCM）+ `KeychainBackupKeyStore` + 默认加密 | `BackupCryptoTests`(8)（AES 真机待验） | W9-1、W9-4（已完成） |
| D45 | 删除全部数据展示清单+二次确认+密钥丢失说明 | 已实现 | `PrivacyGateService.deletionPlan/deleteAll` + `DataDeletionView`（逐字确认 + 密钥警告） | `PrivacyGateServiceTests`(7) | W9-8（已完成） |

### 3.6 第六轮（D46–D54）：会话、通知、生成控制、诊断

| 编号 | 决策摘要 | 状态 | 代码证据 | 测试证据 | 承载任务 |
|---|---|---|---|---|---|
| D46 | 会话创建/切换/删除/重命名/置顶/归档/排序/最近活动 | 已实现 | `GRDBConversationAdminRepository` + `ConversationListView` | `ConversationAdminTests`(13) | W3-1（已完成） |
| D47 | 可手动建会话；AI 可主动建会话但遵守设置 | 已实现有证据（策略 + 数据层 + 后台接线；App 编译待手动触发） | 手动建会话已完成；AI 主动建会话：`NewConversationPolicy`（标题规范化、同主题复用含公共实词片段、去重键、每日 2 个、6 小时间隔、时钟回拨不绕过）+ `ProactiveConversationService`（过 `AutonomyGate` 的 newConversation 分项，新建 kind=proactive 或复用，每次判断写 `autonomy_runs`，去重键存 `detail_json`，无新增迁移）+ `ProactiveScheduler.enqueueNewConversationIfDue`（每天最多一次）+ 专用提示词（reason 复用为话题名）+ runner 链路（建会话 → 写开场消息 → 通知）（`c7dcf59`/`effa97f`） | `NewConversationPolicyTests`(15)、`ProactiveConversationServiceTests`(9)、`ProactiveSchedulerTests` 新增 4 项、`ConversationAdminTests`(13) | W3-2 + W8A |
| D48 | 通知三档（完整/简短/隐藏）+ 按类型设置 | 已实现（通道接线） | `NotificationTiering` + `notifyLevel` + `ProactiveNotificationService`（授权/投递/撤销/清空）+ 设置页分档与自检 | `testNotificationTiering`；App 编译 `6c33f4f` | W7-4 |
| D49 | 生成停止/暂停/继续；保留已生成并可从原上下文继续 | 已实现有证据（核心逻辑 + App 接线；App 编译待手动触发） | `ChatOrchestrator.continueTurn` 契约 + `ChatOrchestratorImpl` 实现（隐藏指令 `origin=system`、`Message.isHiddenInstruction` 界面过滤，`236cd8c`）；`ConversationCoordinator` `PauseGate` 暂停闸门 + `pauseTurn/resumeTurn` + 暂停/继续事件；`ChatViewModel.pause/resumeGeneration/continueWriting`；停止沿用既有取消链路。**暂停只挂起界面消费，模型请求不取消**（ADR-10） | `ChatTurnPhaseTests` 8 项（含 `canContinueWriting` / `isHiddenInstruction`） | W2-6（`236cd8c`） |
| D50 | 主动消息删除/收藏/不感兴趣/触发原因/关联记忆 | 已实现（数据层 + 后台补算） | `ProactiveMessageService`（`8b69a40`）+ `BackgroundRefreshService` 过期清理/补算（`6c33f4f`） | `ProactiveMessageServiceTests` 7 项 | W7-6 |
| D51 | 归档可检索；删除保留记忆并可批量管理 | 已实现有证据（数据层 + App 界面） | `setArchivedBatch`（`4cff077`，main 保护 + 幂等计数）+ 归档会话仍进 `message_fts`/统一检索；删除会话保留记忆沿用 `delete/deleteBatch`；App 层 `ConversationListView` 多选批量归档 + 二次确认 + 结果回报（`310a940`） | `ConversationArchiveBatchTests`(4)、`UnifiedSearchTests`(10)、`ConversationAdminTests`(13)，run 43697137498；App 编译待手动触发 `app-build-check` | W2-5 数据层 + W6 界面（`310a940`）。失败恢复：批量操作单事务，失败即整体不生效 |
| D52 | 完整状态显示（发送/失败/取消/思考/生成/多消息） | 已实现有证据（界面状态机 + App 接线） | `ChatTurnPhase` 七态（等待/思考/生成/暂停/完成/失败/停止）+ `canTransition` 非法跃迁拦截（`236cd8c`）；`ChatViewModel.phase` 由 `turnOpened`/增量/终态/暂停事件驱动；`ChatView` 头部状态文案、暂停/继续按钮、消息滚动只在非暂停时追加 | `ChatTurnPhaseTests` 8 项 | W2-6（`236cd8c`） |
| D53 | 错误含原因与建议；诊断日志导出；脱敏诊断包 | 已实现有证据（诊断日志文件导出仍由 App 层 `DiagnosticsService` 承担，未编译验证） | `ErrorDiagnoser`：17 类失败（密钥缺失/401·403/429/额度/超时/离线/404 模型/上下文超长/400/5xx/预算/只读/空间/备份损坏/升级未完成/权限/未知），每类给出原因、至少一条建议、是否可重试、是否需用户操作；判定顺序固定且不区分大小写；结论不回显原始错误全文（避免泄露密钥与路径）；聊天页错误提示改用 `diagnosedMessage`（headline + 首条建议）。B1-L1 失败原因脱敏、`IntegrityChecker`、`DiagnosticsService`/`DiagnosticExporter` 继续保留 | `ErrorDiagnosisTests`(7，含 16 条归类断言)、`ChatOrchestratorFailurePathTests`，run 43724845883 | W10-3、W9O（`59561a2`） |
| D54 | 自动发送技术实现自定，但不得绕过授权/频率/成本/隐私 | 已实现 | `AutonomyGate.evaluate`（暂停/授权/免打扰/上限/间隔/预算）+ 每次拦截写 `autonomy_runs` | `AutonomySchedulingTests` 8 项 | W7-3 |

### 3.7 第七轮（D55–D62）：基础体验、离线、模型资源、自主验收

| 编号 | 决策摘要 | 状态 | 代码证据 | 测试证据 | 承载任务 |
|---|---|---|---|---|---|
| D55 | 未读数量/标记/全部已读/未读筛选/定位 | 已实现 | `conversations.unread_count/last_read_at` + `markAllRead` + 列表徽标 | `ConversationAdminTests`(13) | W3-3（已完成） |
| D56 | 历史分页、自动加载更早、保留位置、日期跳转、搜索定位 | 已实现有证据（数据层 + App 接线） | `MessageRepository.page(in:before:limit:)`（双键游标）+ 新增 `page(in:around:limit:)`（协议默认兜底 + GRDB 直查，`236cd8c`）；`ChatViewModel`：首屏一页 + `historyCursor`、`loadOlderMessages`（头部插入去重、不跳位）、`jumpToDate`、`locate`（最多回溯 20 页）并复用到会话内搜索与全局搜索命中；`ChatView` 顶部"加载更早"入口 + "跳到日期…" | `MessagePagingTests`、`MessageDateJumpTests` 4 项 | W2-5 + W2-6（`236cd8c`） |
| D57 | 附件删除前检查引用、查看引用、解除、批量清理 | 已实现有证据（数据层 + App 界面） | `GRDBAttachmentReferenceService`（`f64f9c3`）：总引用/活引用区分、被活消息引用默认拒绝（`inUse`）、`force` 先解除再软删、`unlinkAll`、清理候选与批量清理（被引用一律跳过、幂等、不刷新首次删除时间）；`library()`（`310a940`）提供引用统计；App 层 `AttachmentLibraryView`/`AttachmentLibraryViewModel`：类型/大小/日期、使用中与陈旧引用区分、删除确认与强制解除、批量清理未引用 | `AttachmentReferenceServiceTests`(14)、`AttachmentLibraryItemTests`(3)，run 43697938991 + 43700580164 | W4-6 数据层 + W6 界面（`310a940`） |
| D58 | 按运行模式说明离线能力；联网后安全恢复任务 | 部分实现（本地离线部分暂缓，ADR-08） | 本地模型管理页（登记/下载/续传/校验/删除，`813b0ad`）+ 后台唤醒补算（`6c33f4f`）；本地离线闭环依赖 N-18，本阶段不投入 | App 编译 `6c33f4f` | W5-6（推理内核 N-18 暂缓） |
| D59 | 隐私说明/数据流向/授权记录/撤销/导出入口 | 已实现有证据（App 层未编译） | `PrivacyConsentKind` 6 类说明与授权记录 + 撤销 + 删除入口；**数据流向**：`DataFlowCatalog` 固定 9 类数据、去向（仅本机/云端模型服务商/用户选择位置）、静态加密、可否撤销与撤销入口，其中 4 类可能离开设备；**导出**：`UserDataExporter` 白名单导出聊天/记忆/日记/人格与关系/附件元数据/提案为单个 JSON，`settings` 与本地模型表整表排除、凭据列名黑名单剔除、空库拒绝；隐私页新增「数据流向」与「导出（含分享）」区块（`858bffe`/`69ae3f1`/`c81f5e2`） | `PrivacyGateTests`(6)、`PrivacyGateServiceTests`(7)、`DataFlowCatalogTests`(6)、`UserDataExporterTests`(6)，run 43715978437 | W9-4、W9L |
| D60 | 模型下载默认 Wi-Fi、可蜂窝、暂停续传、显示存储 | 已实现（含 App 接线） | 下载器（`f8a1693`）+ `WiFiOnlyNetworkGate`（`NWPathMonitor`）+ 模型管理页进度/存储（`813b0ad`） | `LocalModelTests`(10) | W5-1（已完成） |
| D61 | 模型文件可独立选择备份；版本/来源/校验和/兼容性 | 部分实现 | 注册表含版本/来源/校验和/上下文；独立备份选择未做 | `LocalModelTests`(10) | W5-1、W9-2 |
| D62 | 高度自主验收（主动聊天/记忆整理/回顾/独立思考/关联/建议 + 记录） | 已实现有证据（服务级闭环 + 五类内容能力；真机 UI/后台唤醒待验） | `HighAutonomyAcceptanceTests` 服务级端到端 7 场景：主动聊天闭环、通知未授权拦截、免打扰只拦打扰类、超预算拦截、自主建会话+复用、行为记录可回溯、五类洞察提案（`dd00bc2`/`1e98014`/`c123e2a`/`8f0a289`）。内容能力：`ReflectionInsight`（闭集 5 类 + 严格 JSON + 证据逐字校验 + 置信度夹取 + 必须用户确认规则）+ `AutonomyInsightService`（证据过滤 → 目标记忆存在性校验 → 只落 `proposals` 待确认提案，不写记忆、不直接打扰、同类不重复）。**剩余缺口**：真机 UI 展示与 iOS 后台唤醒验收（非代码缺口） | `ReflectionInsightTests`(20)、`AutonomyInsightServiceTests`(9)、`HighAutonomyAcceptanceTests`(7) | W8C、W9D |

### 3.8 第八轮（D63–D70）：安全、设置、长期维护

| 编号 | 决策摘要 | 状态 | 代码证据 | 测试证据 | 承载任务 |
|---|---|---|---|---|---|
| D63 | Face ID、独立密码、后台锁定、失败保护、锁定时间 | 已实现 | `PrivacyGate`（状态机/密码哈希/失败锁定）+ `AppLockController` + `AppLockView` + `Info.plist NSFaceIDUsageDescription` | `PrivacyGateTests`(6)、`PrivacyGateServiceTests`(7)（Face ID 真机待验） | W9-7（代码完成） |
| D64 | 首启向导（可跳过非必要步骤） | 已实现 | `OnboardingView`（4 步，可跳过）+ `onboarding.completed.v1` + `RootView` 引导 | 编译期校验 | W10-1（已完成） |
| D65 | 主题/背景/气泡/字体/头像 + 恢复默认 | 已实现有证据（App 编译待手动触发） | `ChatTheme`（主题/背景/气泡/字号/头像 + **appearance：跟随系统/浅色/深色**，旧 JSON 缺键回落、非法值归一）+ `RootView.preferredColorScheme` 全局应用 + `.chatThemeChanged` 广播 + 聊天页外观弹层 + 设置页外观入口（`AppearanceSettingsView`，含当前摘要与恢复默认），`5d2e6be` | `ChatThemeAppearanceTests`(5)、`ChatInteractionTests` 主题用例 | W2-7、W9D |
| D66 | 存储分类展示、清理建议、空间预警、不自动删重要数据 | 已实现 | `DiagnosticsView`（数据库/附件/备份分类 + 空间预警）+ `DiagnosticsService.storageUsage`；不自动删除 | `DiagnosticsTests`(7) | W10-4（已完成） |
| D67 | 升级前检查/备份/迁移/兼容/失败恢复/记录/回退 | 已实现有证据（真机升级演练待执行） | `UpgradeGuard`（全新/升级/已最新/拒绝四类计划、未知版本与降级拒绝、备份要求、状态机）+ `UpgradeRecordService` + `AppDatabase.upgradeOnLaunch/retryMigration`（先判断再迁移，拒绝时只读不迁移，全过程写 `upgrade_records`）（`67d51bc`）；**升级前自动备份**：`PreUpgradeBackupPolicy`（是否备份/目录名安全化/保留清理纯逻辑）+ `PreUpgradeBackupService`（主库 + WAL/SHM 一起复制 + manifest.json + 保留最近 5 份）+ 启动升级前执行备份并登记 `backup_manifests(kind=pre_upgrade)`，`upgrade_records.pre_upgrade_backup_id` 与 `integrity_json` 记录结果；备份失败不阻断启动但留痕（`fc56e3f`/`76e6c9f`） | `UpgradeGuardTests`(7)、`UpgradeRecordServiceTests`(6)、`PreUpgradeBackupPolicyTests`(9)、`PreUpgradeBackupServiceTests`(7，含 v13→v14 真实升级自动备份与审计断言)，run 43714304218 | W1-7、W9E、W9H（`fc56e3f`） |
| D68 | 自主程度分项控制、暂停、恢复默认、执行记录 | 已实现（数据层） | `AutonomyService.savePolicy/pause/resume/resetToDefault` + `autonomy_controls` + `autonomy_runs` | `testSavePolicyPersistsAndIsReadBack`、`testPauseBlocksThenResumeAllows`、`testResetToDefault` | W7-2 |
| D69 | 权限按需申请、管理、状态说明、拒绝后替代方案 | 已实现有证据（App 编译待手动触发） | `PermissionAdvisor`（三类权限、状态归一、启动永不申请、仅首次使用可申请、拒绝→系统设置、系统限制不重复询问、每类用途与替代方案）+ `PermissionCenterView`（真实系统状态 + 按需申请 + 去系统设置）；设置页入口（`abf2940`） | `PermissionAdvisorTests`(8) | W10-2、W9D |
| D70 | 版本号/更新日志/反馈/诊断/兼容/健康检查/风险提示 | 已实现有证据（App 编译待手动触发） | 版本号 + `ChangelogView` + `IntegrityChecker` 健康检查 + `DiagnosticsView` + `FeedbackReportBuilder`（只含版本与计数、描述截断、固定隐私声明）+ `FeedbackView`（预览/分享/复制）；设置页入口（`abf2940`） | `FeedbackReportTests`(5)、`DiagnosticsTests`(7) | W10-3、W9D |

### 3.9 第九轮（D71–D72）：多模态与交付范围

| 编号 | 决策摘要 | 状态 | 代码证据 | 测试证据 | 承载任务 |
|---|---|---|---|---|---|
| D71 | 不做 TTS；语音输入/识别/播放全控制；图片理解/OCR/多图；图片生成作扩展 | 部分实现（本地多模态部分暂缓，ADR-08） | `VoiceRecorder`/`AudioPreviewPlayer`/`VoiceInputSheet` + Vision OCR + `ImageUnderstandingSheet`（多图分析复用 `image_analyses`）；本地多模态依赖 N-18，本阶段不投入 | `ChatTurnImageTests`(4) | W4-1～W4-5（本地部分暂缓） |
| D72 | 多设备用备份恢复；恢复前保护备份/独立副本/用户决定替换；语言日期时区；分阶段交付 | 已实现有证据（App 层未编译；真机换机演练待执行） | **时区/日期**：`LocalDay`（dayKey/日界/日期键↔毫秒/加减天数全部显式时区，非法时区回落当前时区，跨夏令时按日历计算）+ `TimeZoneChange`（首次运行不算变化，提示已存日记日期不回改）；**跨设备恢复**：`BackupSnapshot.sourceDeviceID` + `device.install_id` 持久化 + `RestoreOriginPolicy`（本机/其他设备/未知、结构版本必须相等、空间与保护备份门禁、跨设备必须确认且提示"整体替换不合并"）+ `BackupService.restore(confirmedCrossDevice:)` + 恢复页跨设备二次确认弹窗 | `LocalDayTests`(9)、`RestoreOriginPolicyTests`(11)、`BackupDeviceOriginTests`(5)，run 43723798853 | W9-3、W10-6、W9N（`8a09f45`/`f088a45`） |

---

## 四、工作包与可执行子任务（替代宽泛标题）

> 每个工作包对应一条 TodoWrite 主任务；子任务为可验证单元，含完成标准与证据要求。
> 证据必须落到：文件路径 + 测试用例名 + CI run（必要时真机记录）。

### W1 数据底座与迁移（v4→v9）

| 子任务 | 内容 | 完成标准 | 代码证据 | 测试证据 |
|---|---|---|---|---|
| W1-1 | `v4_persona` 迁移 | 迁移可空库/旧库执行，指纹可复算 | `Migrations/V4Persona.swift`、`MigrationID` | `MigrationV4Tests` 10 项 + CI |
| W1-2 | `v5_autonomy` 迁移 | 话题/意图/自主运行/会话未读归档表就位 | `Migrations/V5Autonomy.swift` | `MigrationV5Tests` |
| W1-3 | `v6_character` 迁移 | 角色/表情/状态表 + `proactive_messages` 扩展 | `V6Character.swift` | `MigrationV6Tests` |
| W1-4 | `v7_meta_backup` 迁移 | 备份清单/恢复日志/升级记录/附件软删列 | `V7MetaBackup.swift` | `MigrationV7Tests` |
| W1-5 | `v8_chat_v2` 迁移 | 消息 edited/revoked/favorite、会话 pin/sort、FTS 扩展、日记与版本 | `V8ChatV2.swift` | `MigrationV8Tests` |
| W1-6 | `v9_astrbot` 迁移 | 迁移批次、待处理区、原始 ID 映射 | `V9AstrBot.swift` | `MigrationV9Tests` |
| W1-7 | 升级安全闭环 | 升级前检查 + 失败回退 + 记录可查 | `AppDatabase` 扩展 | 注入失败用例 |

### W2 聊天与消息全交互

| 子任务 | 内容 | 完成标准 | 代码证据 | 测试证据 |
|---|---|---|---|---|
| W2-1 | 多气泡协议 | 一条回复可拆多气泡，每条有独立 messageID 与状态 | `OrchestratorEvent` 扩展、`SegmentParser` | 分段/顺序/失败用例 |
| W2-2 | 状态全显 | 发送/失败/取消/思考/生成/多消息可区分 | `MessageBubble`、`MessageStatus` | UI 状态快照测试 |
| W2-3 | 编辑与撤回 | 编辑留痕可查；撤回显示提示且不删原文 | 新仓储方法 | 编辑链、撤回链用例 |
| W2-4 | 删除体系 | 逐条/批量/按日期关键词筛选/清空会话 | 仓储 + UI | 四类删除用例 |
| W2-5 | 会话内搜索与定位 | 关键词命中、跳转原文、保留位置 | 分页 + FTS | 定位用例 |
| W2-6 | 暂停/继续生成 | 停止保留内容；可从原上下文继续 | `ChatOrchestrator` | 暂停-继续-取消三态用例 |
| W2-7 | 主题与气泡个性化 | 主题/背景/字体/头像 + 恢复默认 | `DesignSystem` | 设置持久化用例 |

### W3 多会话与记忆联动

| 子任务 | 内容 | 完成标准 | 代码证据 | 测试证据 |
|---|---|---|---|---|
| W3-1 | 会话管理全操作 | 建/切/删/重命名/置顶/归档/排序/最近活动 | 会话仓储 | 全操作用例 |
| W3-2 | 主动建会话 | 话题明显不同时可建，遵守用户开关 | 话题检测器 | 触发与抑制用例 |
| W3-3 | 未读体系 | 未读数/标记/全部已读/筛选/定位 | 会话仓储 | 未读状态机用例 |
| W3-4 | 删除保留记忆 | 归档可检索；删除会话后记忆仍在并可批量管理 | 记忆来源关联 | 删除-记忆留存用例 |

### W4 多模态：图片、语音、文件

| 子任务 | 内容 | 完成标准 | 代码证据 | 测试证据 |
|---|---|---|---|---|
| W4-1 | 图片理解 | 可发送图片并纳入上下文；能力上限明确提示 | 附件 → 模型消息 | 端到端（Mock）用例 |
| W4-2 | OCR + 文字搜索 | 设备端优先；命中可定位到图片 | OCR 适配层 | OCR 结果入库与检索用例 |
| W4-3 | 多图分析与比较 | 同轮多图可比较并给出结论 | 多附件上下文 | 多图用例 |
| W4-4 | 语音输入与播放 | 录制/转写/重转写/播放/暂停/进度/连续/后台/倍速/耳机/恢复 | 音频服务 | 播放状态机用例 |
| W4-5 | 附件库 | 原图+缩略图、查看/放大/下载/分享、来源时间关联 | `AttachmentStore` 扩展 | 附件生命周期用例 |
| W4-6 | 文件能力分级 | 明确区分保存/预览/读取/模型理解；删除前查引用 | 引用检查器 | 引用阻断删除用例 |

### W5 模型系统（Local / Cloud / Hybrid）

| 子任务 | 内容 | 完成标准 | 代码证据 | 测试证据 |
|---|---|---|---|---|
| W5-1 | 本地模型仓库 | 下载（Wi-Fi/蜂窝）、暂停续传、存储需求、校验和、版本 | `DFLocalModel` | 仓库状态机用例 |
| W5-2 | 上下文长度实测 | 在真实设备给出可用长度与降级策略 | 实验记录 | 真机报告（E4） |
| W5-3 | 本地运行时接入 | 文字/图片理解/ASR 可跑；不做 TTS | 运行时适配 | 推理冒烟用例 |
| W5-4 | TaskRouter + 结构化输出 | 按任务选模型；应用层工具调用与结构化输出可靠 | `TaskRouter` | 路由决策用例 |
| W5-5 | 预算与成本 | 每日/单次/自主预算、未知费用保守计入、跨日重置、并发不可绕过 | `DFCore/Budget/Budget.swift`、`DFData/BudgetService.swift`、`V13CostLedger.swift`、`Features/Settings/BudgetCenterView.swift` | `BudgetTests`(13)、`BudgetServiceTests`(12)、`ChatOrchestratorBudgetTests`(4)、`MigrationV13Tests`(3) |
| W5-6 | 离线声明与恢复 | 按模式说明能力；联网后安全恢复任务 | 模式检测 | 断网-恢复用例 |

### W6 人格、关系、日记、角色

| 子任务 | 内容 | 完成标准 | 代码证据 | 测试证据 |
|---|---|---|---|---|
| W6-1 | 核心人格保护 | 仅用户可改；AI 只能提案 | 仓储写保护 | 越权写入被拒用例 |
| W6-2 | 外围成长 | 低风险自动、高风险确认；可暂停 | 成长服务 | 分级提案用例 |
| W6-3 | 版本与回退 | 每次变更全量快照，可查看/回退 | `persona_versions` | 版本回退用例 |
| W6-4 | 人格导入 | AstrBot/JSON/MD/TXT 四格式；失败留痕 | `persona_imports` | 四格式 + 失败用例 |
| W6-5 | 人格提案闭环 | 提案-确认-应用-回退全链路 | `proposals` | 提案状态机用例 |
| W6-6 | 关系档案 | 阶段/共同经历/转折；阶段变更需确认 | `RelationshipService` + `relationship_*`（`3229cb8`） | `RelationshipServiceTests` 11 项（run 43643792713） |
| W6-7 | 日记 | 第一人称、可双方编辑、留版本、可成记忆源、结构化记录关系变化 | `diary_entries` + 版本 + `V12DiaryStructure`（`e930a44`）+ `Features/Diary/*` | `DiaryTests` 13 项、`MigrationV12Tests` 9 项、`DiaryMemoryServiceTests` 5 项（run `43680552034`） |
| W6-8 | 角色形象 | 表情/动作/情绪反馈，分阶段 | `characters/character_states` | 状态切换用例 |
| W6-9 | 表达真实性 | 区分真实互动/推断/想象，禁止伪造经历 | Prompt 约束 + 校验 | 伪造拦截用例 |

### W7 自主陪伴与主动联系

| 子任务 | 内容 | 完成标准 | 代码证据 | 测试证据 |
|---|---|---|---|---|
| W7-1 | 意图生成 | 从记忆/时间线产生意图，带证据 | `ProactiveIntentService`（严格 JSON、证据逐字校验、`conversation_intents` 落库）+ `ProactiveScheduler`（久未说话触发）+ `ProactiveIntentRunner`（后台/启动接线，过五重闸门后写会话与通知） | `ProactiveIntentServiceTests`(11)、`ProactiveSchedulerTests`(8) |
| W7-2 | 自主度分项控制 | 主动聊天/记忆整理/日记/反思/成长分别可控；可暂停/恢复默认 | `AutonomyService.savePolicy/pause/resetToDefault`（`0fb3f3f`） | `AutonomyServiceTests.testSavePolicyPersistsAndIsReadBack/testPauseBlocksThenResumeAllows/testResetToDefault` |
| W7-3 | 发送闸门 | 勿扰/间隔/日上限/预算/授权全不绕过 | `AutonomyGate.evaluate`（含暂停/授权/预算）+ `AutonomyService.evaluateSend` | `AutonomySchedulingTests` 8 项 + `AutonomyServiceTests` 六项闸门用例 |
| W7-4 | 通知分档 | 完整/简短/隐藏 + 按类型 | `NotificationTiering`；按类型由分项开关控制 | `testNotificationTiering`、`testUnauthorizedNotificationBlocksUnlessHidden` |
| W7-5 | 后台与补算 | 后台失败下次启动补算；不私换模型 | `AutonomyService.backfill/dueTasks/expireStale` + `AutonomyBackfill` | `testBackfillCreatesMissingDailyTasks`、`testBackfillReportsOverdueAndExpiresStale` |
| W7-6 | 主动消息治理 | 删除/收藏/不感兴趣/减少类似/查看触发原因 | `ProactiveMessageService`（`8b69a40`） | `ProactiveMessageServiceTests` 7 项；治理 UI 属 W10 |
| W7-7 | 自主验收 | 六类行为可观测 + 任务记录 + 补算记录 | `autonomy_runs`（每次放行/拦截/结束都留痕） | `testEveryEvaluationLeavesRunRecord`；验收视图属 W10 |

### W8 记忆七层与三主体治理

| 子任务 | 内容 | 完成标准 | 代码证据 | 测试证据 |
|---|---|---|---|---|
| W8-1 | L1 抽取 | 真实聊天 → 候选记忆，带来源 | 抽取器 | 抽取精度用例 |
| W8-2 | L2/L3 加工 | 情景与实体事实生成、合并、纠错 | `episodes`、`entity_facts` | 合并去重用例 |
| W8-3 | L4/L5 | 程序记忆与反思生成，置信度可追溯 | `procedural_memories`、`reflections` | 反思入库用例 |
| W8-4 | L6/L7 | 时序图谱与阶段性总结，标注派生 | `kg_nodes/kg_edges` | 图谱增边用例 |
| W8-5 | 三套记忆治理 | user/shared/self 分类、暂存 pending、权重 0.6 | `classification_*` | 分类与回滚用例 |
| W8-6 | 记忆管理 UI | 单条/分类/三套/按来源批量删除 | `MemoryView` 扩展 | 批量操作用例 |
| W8-7 | 全局检索 | 聊天+记忆+日记+附件文字统一检索与定位 | FTS 扩展 | 跨域检索用例 |

### W9 备份、恢复、迁移、安全

| 子任务 | 内容 | 完成标准 | 代码证据 | 测试证据 |
|---|---|---|---|---|
| W9-1 | 本地数据加密 | 敏感字段/库加密，密钥用户可控 | 加密层 | 加解密一致性用例 |
| W9-2 | 备份体系 | 手动/自动/增量、默认加密、位置与保留数量、明文需二次确认 | `backup_manifests` | 备份矩阵用例 |
| W9-3 | 恢复体系 | 预览/范围/兼容/空间检查/保护备份/独立副本；失败不破坏现库 | `restore_logs` | 失败不破坏用例 |
| W9-4 | 隐私与数据流向 | 说明、授权记录、撤销、导出入口 | 隐私中心 | 授权流转用例 |
| W9-5 | AstrBot 迁移 | 17183 聊天/5121 记忆/10 天日记/人格/关系全量映射 | `V9AstrBot` + 迁移器 | 数量/指纹校验用例 |
| W9-6 | 待处理区与校验 | 未识别数据留原始内容；迁移前后校验/重试/回滚 | `import_pending` | 失败留痕用例 |
| W9-7 | 门禁安全 | Face ID/独立密码/后台锁定/失败保护/锁定时间 | 安全服务 | 锁定策略用例 |
| W9-8 | 数据删除 | 清单展示 + 二次确认 + 密钥丢失警告 + 备份单独决定 | 删除流程 | 删除清单用例 |

### W10 交付与验证

| 子任务 | 内容 | 完成标准 | 代码证据 | 测试证据 |
|---|---|---|---|---|
| W10-1 | 首启向导 | 模型/人格/迁移/备份/通知/隐私，可跳过 | 向导视图 | 向导流程用例 |
| W10-2 | 权限治理 | 按需申请 + 状态说明 + 拒绝后替代 | 权限层 | 拒绝场景用例 |
| W10-3 | 诊断与反馈 | 错误原因+建议、脱敏诊断包、更新日志、健康检查 | 诊断模块 | 脱敏用例 |
| W10-4 | 存储与维护 | 分类占用、清理建议、空间预警、后台限制说明 | 存储面板 | 统计用例 |
| W10-5 | 真机验收 | 关键链路真机记录（含 iOS 后台边界） | 验收报告 | E4 |
| W10-6 | 时间与时区 | 统一时间存储、跨时区正确显示 | 时间层 | 时区用例 |
| W10-7 | CI 与 IPA | 三包测试绿 + 未签名 IPA 可出 | `.github/workflows` | run 链接 |

---

## 五、缺口与阻塞

| 编号 | 类型 | 内容 | 影响 | 处理 |
|---|---|---|---|---|
| G-01 | 阻塞 | 无本地 Swift/Xcode | 只能靠 CI 验证 | 小步提交 + 高密度评审 |
| G-02 | 阻塞 | 无 iPhone 17 Pro 实测通道 | D02/D62/W5-2/W10-5 无法闭环 | 代码就绪后交用户真机执行 |
| G-03 | 阻塞 | AstrBot 附件本体缺失（92 图片/4 文件/2 图文） | 附件迁移无法用真实数据验收 | 标记待补充，不伪装完成 |
| G-04 | 缺口 | App 层 0 单测 | UI/协调器无回归保护 | W10 新增 App 层测试目标 |
| G-05 | 缺口 | 日记/搜索/安全/备份表未建 | 多领域无法开工 | W1-4～W1-6 |
| G-06 | 待确认 | 本地模型具体选型与体积预算 | 影响 W5-1/W5-3 方案 | 用户授权范围内由技术侧先做候选评估，最终安装包体积需用户确认 |
| G-07 | 待确认 | 远程服务器调度（D21）是否引入 | 涉及成本与隐私 | 默认不引入，需用户单独决定 |

---

## 六、与 10 项宽泛待办的差异说明

| 旧待办（宽泛） | 问题 | 处理 |
|---|---|---|
| "完成 V2.0 重构" | 无验收标准、无法判断完成 | 拆为 W1–W10 |
| "做聊天 UI" | 未覆盖编辑/撤回/多气泡/未读/搜索 | 拆为 W2-1～W2-7 |
| "做记忆系统" | 未区分 L1–L7 与三主体治理 | 拆为 W8-1～W8-7 |
| "做多模态" | 未区分图片/OCR/语音/文件 | 拆为 W4-1～W4-6 |
| "做本地模型" | 未含下载/校验/预算/路由 | 拆为 W5-1～W5-6 |
| "做主动性" | 未含闸门/通知/后台补算/验收 | 拆为 W7-1～W7-7 |
| "做安全与备份" | 混装两类需求 | 拆为 W9-1～W9-8 |
| "做迁移" | 未含待处理区与校验回滚 | 拆为 W9-5～W9-6 |
| "做测试与发版" | 未含真机与 IPA 门禁 | 拆为 W10-1～W10-7 |
| "更新文档" | 无证据链要求 | 并入本文件与台账 |

**结论：10 项不是完整开发清单，只是工作包；完整任务量为 10 个工作包 / 68 个子任务，全部可验证。**

---

## 七、审查批次记录

| 批次 | 日期 | 结论 |
|---|---|---|
| R1 | 2026-11-15 | 首次建立 72 项逐条追溯；确认 10 项仅为工作包；缺口 7 项（阻塞 3、缺口 3、待确认 2）；v4_persona 代码完成待 CI |

### R2 审查增量（2026-11-15）

本轮新增已合并（或已推送待 CI）的证据链：

| 能力 | 承载决策 | 代码 | 测试 | 状态 |
|---|---|---|---|---|
| 多气泡协议 | D52 | `SegmentParser.swift`、`OrchestratorEvent.assistantSegmented` | `SegmentParserTests`(9)、`MultiBubbleTurnTests`(5) | 通过（`7dc81d9`） |
| 编辑/撤回/收藏/删除/搜索/主题 | D22、D23、D24、D25、D26、D65 | `ChatInteractions.swift` + 4 个 GRDB 仓储 + ChatView/ChatViewModel | `ChatInteractionTests`(13) | 通过（`7dc81d9`） |
| 多会话管理 | D46、D47（部分）、D51、D55、D11 | `ConversationAdmin.swift`、`GRDBConversationAdminRepository.swift`、`ConversationListView.swift` | `ConversationAdminTests`(13) | 通过（`c7e8d62`） |
| 附件/OCR/多图/语音文本 | D27、D28（部分）、D29、D17、D71（部分） | `V10Multimodal.swift`、`GRDBMultimodalRepositories.swift`、`MediaProcessing.swift` | `MigrationV10Tests`(10)、`MultimodalTests`(14) | 数据层通过；媒体管线仅编译级 |
| 本地模型注册 | D60、D61、D58（部分）、D02（记录） | `V11LocalModels.swift`、`GRDBLocalModelRepository.swift` | `MigrationV11Tests`(10)、`LocalModelTests`(10) | 待验证（`7f5ec55`） |
| 日记 | D33、D34、D35 | `Diary.swift`、`GRDBDiaryRepository.swift`、`V12DiaryStructure.swift`、`Features/Diary/*` | `DiaryTests`(13)、`MigrationV12Tests`(9)、`DiaryMemoryServiceTests`(5) | 数据层通过（`43680552034`）；界面仅编译级，真机未验 |
| 自主闸门 | D13、D14、D54、D68（部分） | `AutonomyGate.swift` | `AutonomyGateTests`(10) | 待验证（`7f5ec55`） |
| 记忆治理 | D19、D12（部分）、D32（存储侧） | `Memory.swift`、`GRDBMemoryRepository.swift` | `MemoryRepositoryTests`(11) | 待验证（`7f5ec55`） |
| 备份/恢复记录 | D08、D09、D20、D40、D41、D42、D43 | `Backup.swift`、`GRDBBackupRepository.swift`、`BackupService.swift`、`BackupCenterView.swift` | `BackupRepositoryTests`(9)、`BackupServiceTests`(12)、`BackupScheduleTests`(9) | 通过（`03ad2cd`） |
| 反思节奏与紧迫度 | W7-AI 自主（N-20 投递侧）、D13、D14、D68 | `DFCore/Autonomy/ReflectionCadence.swift`、`AutonomyGate.swift`、`DFData/AutonomyService.swift`、`ProactiveIntentService.swift` | `ReflectionCadenceTests`(21)、`AutonomyGateRhythmTests`(8)、`AutonomyServiceRhythmTests`(5) | 通过（`236cd8c`） |
| 生成状态与历史分页 | D49、D52、D56 | `DFCore/Chat/ChatTurnPhase.swift`、`ChatOrchestrator.swift`、`DFData/ChatOrchestratorImpl.swift`、`App/Coordination/ConversationCoordinator.swift`、`Features/Chat/*` | `ChatTurnPhaseTests`(8)、`MessageDateJumpTests`(4)、`MessagePagingTests` | 通过（`236cd8c`）；App 编译未触发（无令牌） |

**仍未闭环（不得标记完成）**：以第三节各条"状态"列为准。当前硬缺口是 N-18 本地推理内核（连带 D01/D03/D04/D05 本地部分）、N-17 真机验收；意图生成（N-20）已接线但依赖可用模型通道；次要缺口包括 D41 厂商 OAuth 云盘、D72 多设备恢复验收。D06 人格文件导入、D18 日记触发人格提案、D42 从文件导入备份、D10 预算与成本控制已实现并有单测（真机交互待验）。

**当前可交付性结论**：核心存储、业务规则、意图生成/闸门接线与 App 层编译均已具备可验证证据；**真机行为与本地推理仍未闭环**，本地推理内核（N-18）是 V2.0 完整性的硬缺口，未签名 IPA 不构成完整交付。

---

## 改进项登记（非正式需求，不代表验收缺口）

| 编号 | 内容 | 归属判断 | 现状 |
|---|---|---|---|
| I-01 | 消息标签**全局重命名**（一处改名，所有消息同步） | 属 D26"标签添加、修改和管理"的正式范围 | **已补齐**（`bcc6ec7`）：`renameTag(_:to:at:)` 单事务改名 + 合并去重，5 项测试；界面标签胶囊右键重命名 |
| I-02 | D25 附件文字命中后**直接预览原图** | 属 D27 附件查看/放大范围，不属于 D25 | **已补齐**（`effa97f`）：搜索命中右键「查看原图」，经 `AttachmentReferenceService.record(id:)` 解析后进入 `AttachmentPreviewView` |
| I-03 | 暂停仅挂起界面消费（模型请求不取消） | ADR-10 已登记的真实边界 | 如需真正断流，须另行设计"取消 + 断点续写"链路 |
| I-04 | `app-build-check` / `build-ipa` 需令牌手动触发 | 交付流程缺口，不是需求缺口 | 本机无 `gh`、无令牌，App 编译本批未验 |


# DaFeiYu V2.0 交付状态与验收报告（滚动更新）

> 生成日期：2026-11-15
> 基线分支：`p1.5/b1`（远程 `github.com/3040525438/DaFeiYu`）
> 性质：**如实状态报告**。已完成项给证据；未完成项明确标注，不以"能编译"冒充"已完成"。
> 配套文档：《DaFeiYu_V2.0_实施台账.md》《DaFeiYu_V2.0_需求追溯矩阵与任务分解.md》

---

## 一、一句话结论

**当前不是完整 V2.0，而是"数据底座 + 核心业务服务 + 主要 App 交互"已落地、本地推理内核仍阻塞的中间态。**
数据库迁移链已推进到 v14；DFCore/DFData 有完整单测并通过 CI；W8B–W10C 五批新增能力（L1–L7 记忆加工、备份加解密与恢复、隐私门禁、首启向导、语音/图片 UI、审批中心、AstrBot 迁移界面）已完成代码落地并通过 `core-tests`；W2-5 检索与整理（D25/D26/D51 数据层）与 D10 预算成本控制已通过 `core-tests`（run 43697137498 / 43694603302）；W6 已把 D25/D26/D51/D57 的 **App 界面接到真实数据层**（`310a940`），但 App 编译需手动触发 `app-build-check`。
**本地模型运行阶段暂缓**（ADR-08）：N-18/N-01 及下载、导入、加载、推理、本地上下文实测不投入；相关需求标"暂缓/部分完成"，不计完成，既有注册表与接口保留。
**仍未完成**：本地模型真实推理内核（N-18，**已暂缓**）、D41 厂商 OAuth 云盘（需 App 注册与密钥，外部权限）、D58 本地离线部分（暂缓）、真机验收与 App 编译证据刷新（最近一次 App 编译证据为 `08dd9cd`；D31/D53/D59/D61/D65/D69/D70/D72 及本轮 D16/D36/D37/D41 的 App 改动需重新手动触发 `app-build-check`）。D03/D04/D31/D36/D37/D53/D59/D61/D67/D72 已于 W9H–W9Q 补齐代码与 CI 证据（run 43714304218 / 43715978437 / 43723798853 / 43724845883 / 43728702351 / 43729249227）；**W9R 补齐 D16 云端语音识别通道、D36 界面渲染接线、D37 情绪数据源、D41 多位置备份**（`d70e6dc`/`8eacbb6`/`fee06dc`，run 43732457414 三包全绿）。上述 App 层改动均未编译、真机未验收。
任何未签名 IPA 仅为"编译产物"，**不得视为完整 V2.0 交付**。

**已产出构建物（2026-11-15）**：
- 未签名实验版 IPA：`E:\temp_20261113_01\_deliverables\DaFeiYuLab-unsigned.ipa`（2,975,713 字节）
- 构建记录：GitHub Actions run `43628905424`（`build-ipa`），产物名 `DaFeiYuLab-unsigned-ipa`
- 包体核验：`Payload/DaFeiYuLab.app`，`CFBundleIdentifier = com.dafeiyu.lab`，版本 `0.1.0`，未签名（需自行签名安装）

---

## 二、已落地的能力（含证据）

| 领域 | 内容 | 代码证据 | 测试证据（CI） |
|---|---|---|---|
| 迁移底座 | v4 persona / v5 autonomy / v6 character / v7 meta_backup / v8 chat_v2 / v9 astrbot / v10 multimodal / v11 local_models / v12 diary_structure / v13 cost_ledger / v14 message_organization | `Packages/DFData/Sources/DFData/Migrations/V*.swift` | `MigrationV4~V14Tests`，`Migrations.latest = .v14_message_organization`，门禁 103 项 |
| 多气泡 | 段落解析、`assistantSegmented` 事件、事务 B 内追加气泡、FTS 同步 | `SegmentParser.swift`、`ChatOrchestrator` | `SegmentParserTests`(9)、`MultiBubbleTurnTests`(5) |
| 消息交互 | 编辑留痕、撤回、收藏、四类删除、会话内搜索、主题存储 | `ChatInteractions.swift`、`GRDB*Repository` | `ChatInteractionTests`(13) |
| 多会话 | 建/改名/置顶/归档/排序/未读/删除保留记忆 + 列表 UI | `ConversationAdmin.swift`、`GRDBConversationAdminRepository.swift`、`ConversationListView.swift` | `ConversationAdminTests`(13) |
| W2-5 统一检索 | 消息/记忆/日记/附件文字四域检索，命中带定位信息（会话/消息/日记日期）+ 原文摘要；归档会话仍可检索；空查询与条数上限有保护 | `DFCore/Search/UnifiedSearch.swift`、`GRDBUnifiedSearchRepository.swift` | `UnifiedSearchTests`(10)、`SearchSnippetTests`(8)，run 43697137498 |
| W2-5 消息整理 | 收藏 / 重要标记 / 分类标签；标签归一化去重、批量单事务、不生成记忆；v14 新增列与标签表 | `Chat/MessageOrganization.swift`、`GRDBMessageOrganizationRepository.swift`、`V14MessageOrganization.swift` | `MessageOrganizationTests`(13)、`MigrationV14Tests`(4)，run 43697137498 |
| W2-5 批量归档 | `setArchivedBatch`（main 保护、幂等计数）；归档可检索；备份快照表序纳入 `message_tags` | `GRDBConversationAdminRepository.swift`、`BackupService.swift` | `ConversationArchiveBatchTests`(4)，run 43697137498 |
| W4-6 附件清理 | 总引用/活引用区分；删除前强校验（被引用默认拒绝，`force` 先解除再软删）；`unlinkAll`、清理候选、批量清理（跳过被引用、幂等）；`library()` 提供逐条引用统计 | `DFCore/Multimodal/AttachmentReference.swift`、`GRDBAttachmentReferenceService.swift` | `AttachmentReferenceServiceTests`(14)、`AttachmentLibraryItemTests`(3)，run 43697938991 + `310a940` |
| W6 App 界面接线 | D25 全局搜索页（四域分组、范围开关、空结果/异常、消息命中切会话定位、记忆/日记详情）；D26 消息整理页（收藏/重要/标签筛选 + 批量标记 + 标签增删反馈，不写记忆）；D51 会话列表多选批量归档（确认 + main 保护提示 + 结果回报）；D57 附件库（类型/大小/引用状态、删除确认与强制解除、批量清理未引用）；AppContainer 注入三套仓储/服务 | `Features/Search/*`、`Features/Chat/MessageOrganizer*.swift`、`Features/Chat/ConversationListView.swift`、`Features/Media/AttachmentLibrary*.swift`、`App/AppContainer.swift` | DFCore 3 项 + DFData 3 项，`310a940` CI；App 编译待手动触发 `app-build-check` |
| W9R 语音/角色/备份 | D16 云端语音识别（multipart 构造与解析、文件名防注入、错误脱敏；语音页设备端/云端切换 + 上传授权，结果以 `speech-cloud:<model>` 落附件文本）；D36 角色在场渲染（`CharacterProfileService` 唯一启用角色 + 聊天页头部表情/动作/互动动画，尊重减弱动态效果）；D37 情绪数据源（`EmotionSignal` 规则推断与衰减 → 编排器提示词 → 每轮落 `character_states`）；D41 多位置备份（`BackupLocationBook` 去重/上限/迁移 + 逐位置复制与结果汇报） | `Packages/DFAI/Sources/DFAI/SpeechTranscriptionWire.swift`、`Packages/DFCore/Sources/DFCore/Persona/EmotionSignal.swift`、`Packages/DFCore/Sources/DFCore/Backup/BackupLocationBook.swift`、`Packages/DFData/Sources/DFData/CharacterProfileService.swift`、`Features/Chat/CharacterPresenceView.swift`、`Features/Media/VoiceInputSheet.swift`、`App/Backup/BackupMirrorService.swift` | `SpeechTranscriptionWireTests`(14)、`EmotionSignalTests`(12)、`BackupLocationBookTests`(19)、`CharacterProfileServiceTests`(5)、`ChatOrchestratorEmotionTests`(3)，run 43732457414；App 层未编译、真机未验 |
| 多模态数据层 | 附件指标、OCR/转写文本 + FTS、多图分析记录 | `V10Multimodal.swift`、`GRDBMultimodalRepositories.swift` | `MigrationV10Tests`(10)、`MultimodalTests`(14) |
| 设备端媒体 | 像素尺寸、缩略图、时长、Vision OCR、端上语音转写、附件入库 | `Features/Media/MediaProcessing.swift`、`AttachmentIngestService.swift` | 仅编译期校验，**未单测、未真机** |
| 本地模型 | 注册表、下载状态与进度、校验和、上下文实测、运行事件 | `V11LocalModels.swift`、`GRDBLocalModelRepository.swift` | `MigrationV11Tests`(10)、`LocalModelTests`(10) |
| 日记 | 一天一篇、全量版本、全文检索、软删重建；结构化记录共同经历/观察/感受/关系变化（关系变化需用户确认） | `Diary.swift`、`GRDBDiaryRepository.swift`、`V12DiaryStructure.swift` | `DiaryTests`(13)、`MigrationV12Tests`(9) |
| 自主闸门 | 总开关/分项/跨午夜免打扰/最小间隔/每日上限/下次允许时间 | `AutonomyGate.swift` | `AutonomyGateTests`(10) |
| 自主调度 | 策略与分项控制、暂停/恢复默认、五重闸门（含暂停/授权/预算）、任务队列、执行留痕、启动补算、通知三档 | `AutonomyGate.swift`、`AutonomyScheduling.swift`、`AutonomyService.swift` | `AutonomySchedulingTests`(8)、`AutonomyServiceTests`(15)，run 43644744193 |
| 主动消息治理 | 记录/发送/抑制、收藏、不感兴趣、减少类似、软删除、触发原因与关联记忆 | `ProactiveMessage.swift`、`ProactiveMessageService.swift` | `ProactiveMessageServiceTests`(7)，run 43644744193 |
| 人格成长 | 核心写保护、提案→审批→应用、全量版本、回退、指纹重算 | `PersonaGrowthService.swift` | `PersonaGrowthServiceTests`(9)，run 43642913413 |
| 关系档案 | 阶段提案→用户确认、历史留痕、过期提案拒绝、共同经历与转折 | `Relationship.swift`、`RelationshipService.swift` | `RelationshipServiceTests`(11)，run 43643792713 |
| 记忆 | 三主体、去重补来源、版本快照、重要度留痕、按来源删除、检索 | `Memory.swift`、`GRDBMemoryRepository.swift` | `MemoryRepositoryTests`(11) |
| 备份 | 备份清单、校验和、恢复日志、保留策略、失败不破坏 | `Backup.swift`、`GRDBBackupRepository.swift` | `BackupRepositoryTests`(9) |
| W8B 记忆加工 | L1–L7 七层定义与治理、候选筛查（证据可定位/类别/重要性）、路由、去重键、冲突检测、合并归档规划、反思结论治理、工作记忆预算装配 | `DFCore/Memory/MemoryProcessing.swift` | `MemoryProcessingTests`(18)，run `b30482a` |
| W9C 记忆服务 | 回合抽取→记忆/人格提案落库、提案审批与驳回、合并归档、反思写入、图谱节点/边、工作记忆存取与过期清理 | `DFData/MemoryProcessingService.swift` | `MemoryProcessingServiceTests`(13) |
| W10A 备份加解密 | AES-256-GCM 容器（`DFBK1` 魔数 + 12B nonce）、32 字节密钥校验、明文/密文双通道、Keychain 密钥存取 | `DFCore/Backup/BackupCrypto.swift`、`CryptoKitBackupCipher.swift`、`App/Security/KeychainBackupKeyStore.swift` | `BackupCryptoTests`(8)（Linux 走替身，AES 真机待验） |
| W10A 备份恢复 | 逻辑快照导出（11 表父→子序）、SHA256 校验、恢复预检、单事务恢复 + 三套 FTS 重建、恢复前自动安全备份 | `DFData/BackupService.swift` | `BackupServiceTests`(7) |
| W10B 隐私门禁 | 锁屏状态机、独立密码哈希 + 盐、失败计数与锁定期、前后台切换、6 类隐私授权、删除清单与逐字确认 | `DFCore/Privacy/PrivacyGate.swift`、`DFData/PrivacyGateService.swift`、`App/Security/AppLockController.swift` | `PrivacyGateTests`(6)、`PrivacyGateServiceTests`(7)（Face ID 真机待验） |
| W10C 审批中心 | 记忆/人格/关系三类提案统一确认与驳回、AstrBot 批次→待处理区→回滚全流程界面 | `Features/Settings/ApprovalCenterView.swift`、`AstrBotImportView.swift` | App 编译期校验 |
| W10B 首启与媒体 | 4 步首启向导、语音录制/转写/回放、图片 OCR + 视觉模型调用链 | `Features/Onboarding/OnboardingView.swift`、`Features/Media/*` | App 编译期校验，真机未验 |
| W8-3 记忆抽取闭环 | 抽取提示词（证据必须逐字、禁止推断）、围栏 JSON 解析、主语→归属、证据定位与去重、回合结束自动抽取入库、`memory.extraction.enabled` 开关 | `DFCore/Memory/MemoryExtraction.swift`、`DFOrchestration/MemoryExtractionCoordinator.swift`、`ChatOrchestratorImpl` 后置钩子 | `MemoryExtractionTests`(8) + `MemoryExtractionCoordinatorTests`(5)，run `df01164` |
| W10A 修复 | 备份按列序号编码，修复恢复时 `conversations.title` 整列写成 NULL | `BackupService.encode` | `BackupServiceTests`(7)，run `554e678` |
| W10-3 诊断与存储 | 脱敏规则（密钥/Bearer/邮箱/手机号/长哈希/个人目录）、诊断报告 Markdown 导出、存储分类（数据库/附件/备份）、空间预警、记录计数 | `DFCore/Diagnostics/Diagnostics.swift`、`DFData/DatabaseStats.swift`、`App/Diagnostics/DiagnosticsService.swift`、`Features/Settings/DiagnosticsView.swift` | `DiagnosticsTests`(7)，run `15eec68` |
| W5 本地模型管理 UI | 登记（来源/大小/SHA-256/规格/仅 Wi-Fi）、下载与断点续传、校验、删除文件（保留登记）、进度与状态机展示；仅 Wi-Fi 用 `NWPathMonitor` 判定 | `App/Models/LocalModelManager.swift`、`Features/Settings/LocalModelsView.swift` | core-tests + app-build-check（`6c33f4f` 通过） |
| N-07 后台刷新接线 | `BGTaskScheduler` 注册（`com.dafeiyu.autonomy.refresh`）、进入后台安排下一次、唤醒时执行过期清理与任务补算 | `App/Background/BackgroundRefreshService.swift`、`App/DaFeiYuApp.swift`、`App/Info.plist` | app-build-check 通过；真机后台唤醒未验 |
| N-08 通知通道 | `UNUserNotificationCenter` 授权申请、三档渲染（完整/简短/不通知）、投递/撤销/清空、状态与链路自检界面 | `App/Notifications/ProactiveNotificationService.swift`、`Features/Settings/NotificationSettingsView.swift` | app-build-check 通过；真机通知未验 |
| W8-2 日记沉淀 | 日记正文 → 情景记忆候选（证据逐字）→ 既有筛查/去重/提案治理 → 回填 `memory_id`，已沉淀不重复抽取 | `DFData/DiaryMemoryService.swift`、`DFCore/Diary/Diary.swift`（`attachMemory`） | `DiaryMemoryServiceTests`(5)，run `87e19b9` |
| D34 日记结构化与界面 | 日记新增共同经历/观察/感受/关系变化四个结构化字段 + 确认标记；版本快照同步扩列；列表/编辑界面（新建、编辑、删除、沉淀为记忆），从空间页进入 | `V12DiaryStructure.swift`、`Diary.swift`、`GRDBDiaryRepository.swift`、`Features/Diary/DiaryView.swift`、`Features/Diary/DiaryEditorView.swift` | `MigrationV12Tests`(9)、`DiaryTests`(13)，core-tests run `43680552034`；App 编译 run `43680140639` |
| N-14 更新日志 | 设置→更新日志：当前版本/构建号/数据库结构版本 + 真实交付批次（含提交引用），明确标注未签名开发版、无对外版本号 | `Features/Settings/ChangelogView.swift`、`SettingsView.swift` 入口 | App 编译 run `43681288275` |
| D41 备份外部导出 | 每份可用备份增加"导出"：读取沙盒内已加密容器，经系统文件面板保存到文件/外部分享位置，不做明文转换；新增 `BackupService.fileURL(for:)` 定位容器 | `Features/Settings/BackupCenterView.swift`、`BackupService.swift` | `BackupServiceTests`(8)，core-tests run `43682798110`、App 编译 run `43682811219` |
| N-20 意图生成与调度接线 | 模型严格 JSON 输出 → 证据逐字校验 → `conversation_intents` → 五重闸门 → 写会话（origin=proactive）+ 主动消息 + 通知；`ProactiveScheduler` 按"久未说话/免打扰/间隔/日上限"排任务；后台唤醒与启动均接线 | `DFData/ProactiveIntentService.swift`、`ProactiveScheduler.swift`、`App/Background/ProactiveIntentRunner.swift`、`BackgroundRefreshService.swift` | `ProactiveIntentServiceTests`(11)、`ProactiveSchedulerTests`(8)，core-tests run `43686013429`、App 编译 run `43686026790` |
| D09 自动备份调度 | 每日首次完整备份 + 数据指纹变化后增量备份（最小间隔 1h），空库跳过、失败不推进时间戳；接入启动与后台唤醒 | `DFCore/Backup/BackupSchedule.swift`、`DFData/BackupScheduleService.swift` | `BackupScheduleTests`(9)，core-tests run `43686013429` |
| N-18 前置：模型文件体检 | 真实文件头识别（GGUF/GGML 系列）、流式 SHA-256、大小/格式/登记值校验；**推理内核仍未接入**，只回答"文件能否交给内核" | `DFAI/LocalModelArtifactVerifier.swift` | `LocalModelArtifactVerifierTests`(6)，core-tests run `43686013429` |
| D41 外部目录备份 | 设置→备份与恢复新增"外部位置"：系统文件选择器授权目录（含 iCloud Drive/第三方网盘在「文件」中的位置），保存安全作用域书签，提供"复制到外部"并校验大小；清除授权不删外部文件 | `App/Backup/BackupMirrorService.swift`、`BackupCenterView.swift` | App 编译 run `43686026790`，真机授权流程待验 |
| D06 人格文件导入 | JSON（sections/items/数组）、Markdown（标题+列表）、TXT（[段落]+key:value）解析，去重/截断/代码块跳过；与外围人格逐条比对后只生成待审批提案，中性内容不产生噪音；核心人格不受影响；空间页入口 | `DFCore/Persona/PersonaFileParser.swift`、`DFData/PersonaFileImportService.swift`、`Features/Settings/PersonaImportView.swift` | `PersonaFileParserTests`(12)、`PersonaFileImportServiceTests`(6)，core-tests `03ad2cd` 通过 |
| D42 从文件导入备份 | 支持导入导出的 `.dfbk` 加密容器与 `.json` 明文备份；加密容器必须能用本机密钥解开，未知表/格式不符直接拒绝；导入只登记备份清单，不自动覆盖数据 | `DFData/BackupService.importBackupFile`、`Features/Settings/BackupCenterView.swift` | `BackupServiceTests` 新增 4 项，core-tests `03ad2cd` 通过 |
| D18 日记触发人格提案 | 日记「观察 / 关系变化」经用户点击后生成外围人格待审批提案；正文与感受不直接变人格；证据保留日记 id、日期与原文；同内容已有条目或待审批提案时跳过 | `DFData/DiaryPersonaProposalService.swift`、`Features/Diary/DiaryEditorView.swift` | `DiaryPersonaProposalServiceTests`(5)，core-tests `03ad2cd` 通过 |
| D10 预算与成本控制 | 新增 `cost_ledger`（v13）与 `BudgetService`：调用前在单个写事务内"读当日花费 + 判定 + 预占"，并发无法绕过；结算按口径分 `confirmed`（服务端用量 + 单价）/ `estimated`（缺用量按字符估算）/ `unavailable`（缺单价时 `cost_yuan` 为 NULL，禁止写 0）；未知费用按 `unknownReserveYuan` 保守计入；按本地 `day_key` 跨日重置；每日 / 单次 / 自主预算接入 `AutonomyGate` 与聊天编排；Provider 请求附带 `stream_options.include_usage`；设置页新增预算与成本中心（上限、单价、今日折算、最近 30 条审计） | `DFCore/Budget/Budget.swift`、`DFData/BudgetService.swift`、`V13CostLedger.swift`、`ChatOrchestratorImpl.swift`、`AutonomyGate.swift`、`App/AppContainer.swift`、`App/Background/ProactiveIntentRunner.swift`、`Features/Settings/BudgetCenterView.swift` | `BudgetTests`(13)、`BudgetServiceTests`(12)、`ChatOrchestratorBudgetTests`(4)、`MigrationV13Tests`(3)，core-tests run `43694603302` 通过；App 编译待手动触发 |
| V2-W7R 反思节奏 + W2-6 生成控制 | ①`ReflectionCadence`：严格 JSON 键集校验、urgency 夹取 0–1、`next_reflection_in` 夹取 60–3600 秒、重启按上次更新时间续算、`CadenceSignals` 快/慢节奏、`ReflectionRhythm` 只收紧；②`AutonomyGate` 增加可选 urgency/cadence 联动（不传时行为不变），`AutonomyService`/`ProactiveIntentService` 透传并留痕；③修复编排器提示词缺少本轮用户输入；④D49 暂停/继续/停止/续写（暂停=挂起界面消费，ADR-10）；⑤D52 `ChatTurnPhase` 七态；⑥D56 分页游标、加载更早、日期跳转、逐页定位 | `DFCore/Autonomy/ReflectionCadence.swift`、`AutonomyGate.swift`、`DFCore/Chat/ChatTurnPhase.swift`、`ChatOrchestrator.swift`、`DFData/ChatOrchestratorImpl.swift`、`AutonomyService.swift`、`ProactiveIntentService.swift`、`App/Coordination/ConversationCoordinator.swift`、`Features/Chat/ChatView.swift`+`ChatViewModel.swift` | `ReflectionCadenceTests`(21)、`AutonomyGateRhythmTests`(8)、`ChatTurnPhaseTests`(8)、`AutonomyServiceRhythmTests`(5)、`MessageDateJumpTests`(4)，commit `236cd8c`（首轮编译失败已由 `d5cc26c` 修复，run 43703524689 通过）；另含 D26 标签全局重命名（`bcc6ec7`，DFData 5 项）；**App 编译未触发（无令牌），不得记为编译通过** |
| V2-W8A D47 主动创建会话 | `NewConversationPolicy` 纯逻辑决策：标题规范化（换行删除、折叠空白、去标点、截断、最少 2 字）、同主题复用（完全相等 / 包含 / 长度 ≥ 2 公共实词片段，带停用词表，归档会话不复用）、去重键、每日 2 个、6 小时最小间隔、时钟回拨不绕过；`ProactiveConversationService` 先过 `AutonomyGate` 的 `newConversation` 分项，再新建（`kind = proactive`）或复用，每次判断写 `autonomy_runs`（done / reuse / skip），去重键存 `detail_json`（无新增迁移）；`ProactiveScheduler.enqueueNewConversationIfDue` 每天最多一次，受总开关/分项/暂停/时间窗/免打扰/沉默时长约束；`ProactiveIntentService` 专用提示词（`reason` 复用为话题名）；runner 链路：模型判断 → 策略决策 → 建会话 → 写开场消息（`origin = proactive`）→ 通知 | `DFCore/Autonomy/NewConversationPolicy.swift`、`DFData/ProactiveConversationService.swift`、`ProactiveScheduler.swift`、`ProactiveIntentService.swift`、`App/Background/ProactiveIntentRunner.swift`、`App/AppContainer.swift` | `NewConversationPolicyTests`(15)、`ProactiveConversationServiceTests`(9)、`ProactiveSchedulerTests` 新增 4 项，commit `c7dcf59` + 修复 `effa97f`；首轮 run 43705107702 失败（换行被转空格、同主题判定过窄），修复后 run 43705600879 通过；**App 编译未触发（无令牌）** |
| V2-W8C D62 高度自主验收 | 服务级端到端 6 场景：①久未说话 → 排任务 → 生成意图 → 五重闸门 → 落库 → `allowed` 记录；②通知未授权时拦截且不写会话；③免打扰只拦打扰类行为，记忆整理与自我反思放行；④超出自主预算拦截并给出原因；⑤自主创建 `kind=proactive` 会话、同主题第二次复用不新建；⑥`allowed`/`blocked` 均可回溯且 `blocked` 必带原因 | `Packages/DFData/Tests/DFDataTests/HighAutonomyAcceptanceTests.swift` | 6 项，commit `dd00bc2` + 编译修复 `1e98014`，run 43706422096 通过（3m13s）；**未覆盖**主动回顾经历、历史记忆关联、值得记录的经历、观点变化、修正建议——内容能力尚未实现，D62 不得记为完成；**App/真机未验收** |
| V2-W9E D67 升级保护 + D29 文件能力分级 | ①D67：`UpgradeGuard` 四类升级计划（全新/升级/已最新/拒绝未知版本与降级）、备份要求、状态机；`AppDatabase` 启动与重试先判断再迁移，拒绝时降级只读，升级全过程写 `upgrade_records`（早于 v7 的库跳过不伪造），失败记 error；②D29：`FileCapabilityCatalog` 按扩展名 + MIME 分级（图片 OCR/理解、音频转写、视频仅播放、文本可读、PDF 仅预览、压缩包仅保存），附件库展示能力摘要 | `DFCore/Support/UpgradeGuard.swift`、`DFData/UpgradeRecordService.swift`、`DFData/AppDatabase.swift`、`DFCore/Multimodal/FileCapabilityCatalog.swift`、`Features/Media/AttachmentLibraryView.swift` | `UpgradeGuardTests`(7)、`UpgradeRecordServiceTests`(6)、`FileCapabilityCatalogTests`(10)；`67d51bc` run 43709142796、`8577e64` run 43709664356 通过；**剩余**：升级前自动备份文件与真机升级演练；App 层未编译验证 |
| V2-W9D D62 内容能力 + D65/D69/D70 | ①D62 五类内容能力：`ReflectionInsight`（闭集 recall_recent / memory_link / worth_recording / stance_change / correction_proposal；顶层与条目严格键集；未知键/缺键/类型错/未知枚举全部拒绝且不崩溃；证据逐字校验忽略空白；置信度夹取 0–1；关联/修正必须有目标记忆 id；除只读回顾外一律必须用户确认）+ `AutonomyInsightService`（证据过滤 → 目标记忆存在且 active → 只落 `proposals(kind=autonomy_insight)` 待确认提案，不写 memories、不产生主动消息、同类同摘要不重复）；验收扩至 7 场景。②D65：`ChatTheme.appearance`（跟随系统/浅色/深色，旧 JSON 兼容）+ `RootView.preferredColorScheme` + `.chatThemeChanged` + 设置页外观入口与恢复默认。③D69：`PermissionAdvisor`（启动永不申请、仅首次使用可申请、拒绝→系统设置、系统限制不重复询问、每类用途与替代方案）+ `PermissionCenterView` 真实状态展示。④D70：`FeedbackReportBuilder`（只含版本与计数、描述截断、固定隐私声明）+ `FeedbackView` 分享/复制 | `DFCore/Autonomy/ReflectionInsight.swift`、`DFData/AutonomyInsightService.swift`、`DFCore/Chat/ChatInteractions.swift`、`Features/Root/RootView.swift`、`Features/Settings/AppearanceSettingsView.swift`、`DFCore/Support/PermissionAdvisor.swift`、`Features/Settings/PermissionCenterView.swift`、`DFCore/Support/FeedbackReport.swift`、`Features/Settings/FeedbackView.swift` | `ReflectionInsightTests`(20)、`AutonomyInsightServiceTests`(9)、`HighAutonomyAcceptanceTests`(7)、`ChatThemeAppearanceTests`(5)、`PermissionAdvisorTests`(8)、`FeedbackReportTests`(5)；`8f0a289` run 43708027206、`5d2e6be` run 43708256051、`abf2940` run 43708607413 通过；**App 层未编译验证** |
| V2-W9F D28 语音附件关联与重转写 | 语音输入把已入库录音 id 交给聊天页，`turnOpened` 时把附件挂到该条用户消息（只建关联，不改正文）；附件库音频/视频支持「重新转写」与「复制转写文本」，重转写只覆盖 `attachment_texts` 同一行；语音页注明设备端转写、音频不上传 | `Features/Media/VoiceInputSheet.swift`、`AttachmentIngestService.swift`、`AttachmentLibraryView(Model).swift`、`Features/Chat/ChatView(Model).swift` | `MultimodalTests.testAudioAttachmentLinksToMessageWithTranscript`；`8821d6b` run 43711243224 通过；**App 层未编译验证**，真机中文转写待验 |
| V2-W9G D16 语音上传授权策略 + D21 后台说明 | ①`SpeechInputPolicy`：设备端/云端/不可用三态，云端未授权或拒绝一律不启动并给文字兜底；②`BackgroundExecutionPolicy`：不承诺准点、成本计入预算、只发最少上下文；设置页新增「后台与运行方式」说明页 | `DFCore/Support/SpeechInputPolicy.swift`、`DFCore/Support/BackgroundExecutionDisclosure.swift`、`Features/Settings/BackgroundSettingsView.swift` | `SpeechInputPolicyTests`(7)、`BackgroundExecutionDisclosureTests`(5)；`f62aca2` run 43711401702 通过；D16 **仍为部分实现**（云端识别通道未接入），App 层未编译验证 |
| V2-W9H D67 升级前自动备份 | 启动升级前先把主库与 WAL/SHM 原样复制到 `<root>/PreUpgradeBackups/<时间戳>-<版本>/` 并写 `manifest.json`；保留最近 5 份（总数含本次，按时间戳数值排序，非数字名优先清理）；备份登记 `backup_manifests(kind=pre_upgrade)`，审计记录写 `pre_upgrade_backup_id` 与 `integrity_json`；备份失败不阻断启动但留痕，全新库跳过 | `DFCore/Support/PreUpgradeBackupPolicy.swift`、`DFData/PreUpgradeBackupService.swift`、`DFData/AppDatabase.swift` | `PreUpgradeBackupPolicyTests`(9)、`PreUpgradeBackupServiceTests`(7，含 v13→v14 真实升级自动备份与审计断言)；`fc56e3f` 首轮 2 处失败 → `2a91471` 语义修正 → `76e6c9f` run 43714304218 全绿 |
| V2-W9I D37 表达三态与情绪约束 | `EpistemicStance`（真实/推断/想象，未知值按推断）+ `EpistemicDisclosure`（事实断言词只许用于真实；想象必须带想象框架词）+ `ExpressionStance`/`ExpressionPolicy`（拒绝须给理由、异议须说清分歧、幽默禁侮辱、任何态度禁情感施压）+ `EmotionState`（强度夹取、三档、语气引导）；`SelfExpressionProtocol.systemFragment` 并入编排器每次请求的 system prompt（真实调用链生效） | `DFCore/Persona/SelfExpression.swift`、`DFData/DFOrchestration/ChatOrchestratorImpl.swift` | `SelfExpressionTests`(18)；`ddadfdc`，最终 run 43714304218 全绿；**情绪状态数据源（`character_states`）尚未接入** |
| V2-W9J D03 工具调用 + D04 结构化输出 | ①`ToolDefinition`/`ToolCallProtocol`：```tool 代码块协议解析，校验未知工具、必需参数、未声明参数、参数类型；无工具时不注入提示词；不执行副作用。②`StructuredOutput`：稳妥提取 JSON（代码块/前后说明/字符串内花括号/转义引号，未闭合返回 nil）+ `StructuredSchema` 校验；`ChatRequest.responseFormat` + `OpenAIWireCodec` 仅在声明时发送 `response_format` | `DFCore/AI/ToolCall.swift`、`DFCore/AI/StructuredOutput.swift`、`DFCore/AI/ChatModel.swift`、`DFAI/OpenAIWireCodec.swift`、`DFAI/OpenAICompatibleProvider.swift` | `ToolCallTests`(14)、`StructuredOutputTests`(17)、`ProviderRequestBodyTests`(4)；`d0a8f5b` DFAI 编译失败 → `a4a1f1e` 修复，run 43714304218 全绿 |
| V2-W9L D59 数据流向与用户数据导出 | ①`DataFlowCatalog`：9 类数据，标注去向（仅本机/云端模型服务商/用户选择位置）、静态加密、可否撤销与撤销入口，4 类可能离开设备，摘要由清单实时计算；②`UserDataExporter`：白名单导出（聊天/记忆/日记/人格与关系/附件元数据/提案）为单个 JSON，`settings` 与本地模型表整表排除、凭据列黑名单剔除、空库拒绝、只读导出；③隐私页新增「数据流向」与「导出（含分享）」 | `DFCore/Privacy/DataFlowCatalog.swift`、`DFData/UserDataExporter.swift`、`Features/Settings/PrivacySettingsView.swift`、`App/AppContainer.swift` | `DataFlowCatalogTests`(6)、`UserDataExporterTests`(6)；`858bffe` Row API 编译失败 → `69ae3f1`、异步 await → `c81f5e2`，run 43715978437 全绿；**App 层未编译验证** |
| V2-W9M D36 动态表情与互动动画 | ①`CharacterMood`/`CharacterAction`/`CharacterAnimation` + `CharacterPresentationPolicy`（精力耗尽入休息、高唤醒挥手、低唤醒静立、亲和低幅度减半、减弱动态效果静止）；②`InteractionAnimationPolicy` 与 `ChatTurnPhase` 七态一一对应；③`CharacterStateService` 单事务更新 + 历史留痕 + 幂等 + 越界夹取 | `DFCore/Character/CharacterPresentation.swift`、`DFData/CharacterStateService.swift` | `CharacterPresentationTests`(15)、`CharacterStateServiceTests`(10)；`cc7f91b`，`a32406f`/`4ea83ce` 修复，run 43723798853 全绿；**界面渲染未接** |
| V2-W9N D72 跨设备恢复与时区 | ①`LocalDay` 显式时区日期工具（dayKey/日界/加减天数，跨夏令时正确）；②`TimeZoneChange` 首次运行不算变化并提示已存日记日期不回改；③备份写入 `sourceDeviceID`，`restore` 结构版本必须相等、跨设备/未知来源必须二次确认（整体替换、不合并、先做保护备份） | `DFCore/Support/LocalDay.swift`、`DFCore/Backup/RestoreOriginPolicy.swift`、`DFData/BackupService.swift`、`Features/Settings/BackupCenterView.swift` | `LocalDayTests`(9)、`RestoreOriginPolicyTests`(11)、`BackupDeviceOriginTests`(5)；`8a09f45`+`f088a45`，`b9e5773` 修可选链，run 43723798853 全绿；**App 层未编译、换机演练未做** |
| V2-W9O D53 错误归类与可执行建议 | `ErrorDiagnoser` 17 类失败归类（本地状态 → HTTP 码 → 网络 → 权限固定顺序），每类给原因、建议、可重试与是否需用户操作；结论不回显原始错误全文；聊天页错误提示改为"原因 + 首条建议" | `DFCore/Support/ErrorDiagnosis.swift`、`Features/Chat/ChatViewModel.swift` | `ErrorDiagnosisTests`(7，16 条归类断言)；`59561a2`，run 43724845883 全绿；App 层未编译 |


---

## 三、尚未完成（不得视为已完成）

| 编号 | 缺口 | 现状 | 阻塞/原因 |
|---|---|---|---|
| N-01 | 本地模型**真实推理运行时** | 只有注册表与事件表，没有推理层 | 需选型、需真机内存/性能实测 |
| N-02 | 模型下载器（Wi-Fi 判定、断点续传、校验和核验） | **已完成**（`f8a1693`，run 43640597662） | 真机大文件与弱网未验证 |
| N-03 | 图片理解/多图理解**调用链** | **已完成（云端视觉通道）**（`bccfb29`）：选图→JPEG→入库→OCR→视觉模型→`image_analyses`→回填草稿 | 本地视觉模型依赖 N-18；真机未验 |
| N-04 | 语音录制/播放 UI 与重转写入口 | **已完成**（`bccfb29`）：录制→端上转写→回放→填入；`AudioPreviewPlayer` 支持暂停/进度 | 真机麦克风权限未验；录音附件与消息未绑定（D28 部分完成） |
| N-05 | 人格成长服务（核心写保护/提案/审批/回退） | **已完成**（`035c872` 数据层 + `bccfb29` 审批 UI） | "低风险自动"分级策略仍为人工确认 |
| N-06 | 关系档案读写与阶段确认 | **已完成**（`3229cb8` 数据层 + `bccfb29` 审批中心关系页 + `78680b6` 五类独立回顾视图） | 回顾页 App 层未编译、真机未验 |
| N-07 | 自主调度器（后台整理、补算、主动发消息） | **数据层 + 后台唤醒接线已完成**（`0fb3f3f`、`b9e829e`、`6c33f4f`）：`BGTaskScheduler` 注册、进入后台排期、唤醒时过期清理与补算 | 意图生成（W7-1）未做；真机后台唤醒未验 |
| N-08 | 通知三档与按类型设置 | **已完成通道接线**（`6c33f4f`）：授权申请、三档渲染、投递/撤销/清空、设置页自检 | 主动内容生成未接入（N-20）；真机通知未验 |
| N-09 | L1–L7 记忆加工（抽取/合并/纠错/反思/图谱） | **已完成**（`b30482a` + `bccfb29`）：七层定义、治理、抽取服务、合并归档、冲突检测、反思、图谱、工作记忆 | 质量评估依赖真实模型输出，真机未验 |
| N-10 | 备份文件加解密与恢复落地 | **已完成**（`bccfb29`）：AES-256-GCM 加密、SHA256 校验、预检、单事务恢复、自动安全备份 | AES 解密真机未验（Linux CI 走替身） |
| N-11 | AstrBot 数据导入器 | **已完成**（`b6ba835` 数据层 + `bccfb29` 迁移界面） | 真实源包路径与大数据量未真机验 |
| N-12 | Face ID / 独立密码 / 后台锁定 | **已完成代码**（`bccfb29`）：锁屏状态机、密码哈希、失败锁定、前后台切换、`AppLockView` | Face ID 真机未验 |
| N-13 | 数据删除清单与二次确认 | **已完成**（`bccfb29`）：清单 + 逐字确认短语 + 密钥丢失说明 + 附件可选 | 真机未验 |
| N-14 | 首启向导、权限治理、诊断导出、存储分类、更新日志 | **已完成**（`bccfb29`、W10-3、`b00227c`）：更新日志页展示真实版本号/构建号/结构版本与已交付批次，不编造发布日期、不冒充对外版本 | 真机未验 |
| N-15 | App 层编译验证 | 已通过（最新 run `43686026790`，`08dd9cd`） | 每次 App 改动后需复跑 |
| N-16 | IPA 产物 | **已重新出包**（run `43686373090`，`08dd9cd`）：正式版 + 实验版未签名 IPA；实验版结构沿用 run `43678102338` 的核验结果（`com.dafeiyu.lab`、后台模式与 BGTask 声明） | 未签名、未安装、未真机验收 |
| N-17 | 真机验收 | **未开始** | 无设备通道 |
| N-18 | 本地模型推理内核（llama.cpp / MLX） | **阻塞（前置体检已完成）** | 已实现模型文件体检（GGUF/GGML 头、流式 SHA-256、大小/登记值）；仓库仍无推理运行时依赖，需引入二进制/SwiftPM 包并真机跑通；不得用空实现冒充 | 需 macOS + 设备 + 运行时产物 |
| N-19 | 模型管理器 UI 与下载任务接线 | **已完成**（`813b0ad`）：登记/下载/续传/校验/删除文件，进度与状态机，仅 Wi-Fi 判定 | 真机大文件与弱网未验 |
| N-20 | 意图生成（W7-1） | **已完成代码**（`08dd9cd`）：严格 JSON、证据逐字、`conversation_intents`、五重闸门、调度/会话/通知接线 | 依赖可用模型通道；离线本地推理仍依赖 N-18；真机未验 |
| N-21 | 聊天编排器接入记忆抽取 | **已完成**（`df01164`）：回合落库后异步抽取→筛查→入库/提案，失败不影响聊天 | 抽取质量依赖真实模型，真机未验 |

---

## 四、已知问题清单

| 编号 | 问题 | 影响 | 处理 |
|---|---|---|---|
| K-01 | 本地无 Swift/Xcode | 只能靠 CI 与人工审查 | 控制提交粒度 |
| K-02 | App 层不参与 push CI | 新增 UI 可能编译失败 | 需手动触发 `app-build-check` |
| K-03 | 历史聊天附件本体缺失 | 附件功能无法用真实数据验收 | 迁移时标记"待补充" |
| K-04 | 迁移版本号字符串排序陷阱 | `v10` 会排在 `v9` 前 | 已改为按 `grdb_migrations.rowid` 与 `MigrationLedger` 校验 |
| K-05 | `MemoryScope.self` 与 Swift 关键字冲突 | 编译失败 | 已改为 `selfScope = "self"`，库内取值不变 |
| K-06 | DFCore 模型成员初始化器默认 internal | DFData 无法构造 | 已为新增记录类型补 `public init` |
| K-07 | 工作区 CRLF/LF 差异 | `git status` 噪声 | 提交时按文件精确 add |
| K-08 | App 层改动本批未经编译器验证（`ConversationCoordinator`、`ChatView`、`ChatViewModel`） | 存在编译错误风险 | 已有 `workflow_dispatch` 的 `app-build-check`；本机无 `gh`/令牌，**阻塞未解除**，需在有令牌环境手动触发 |
| K-09 | 编排器此前未把本轮用户输入放进提示词 | 模型只能看到上一轮以前的上下文（云端闭环缺一环） | 已在 `236cd8c` 修复并做重试去重；建议在真机验收 B 组补一条"连续两轮追问"用例 |
| K-10 | D26 标签只能逐条添加/删除，没有全局重命名 | 管理成本高 | **已补齐**（`bcc6ec7`）：`renameTag` 单事务改名并合并去重，界面右键重命名 |
| K-11 | D25 附件文字命中后不能直接预览原图 | 命中后只能跳到消息 | **已补齐**（`effa97f`）：搜索命中右键「查看原图」，直接进入 `AttachmentPreviewView` |

---

## 五、真机验收清单（必须人工执行，未执行即未验收）

### A. 基础与启动
1. 安装实验版（`com.dafeiyu.lab`），确认未覆盖正式版 `com.dafeiyu.app`。
2. 首启建库成功；`schema_version = v11_local_models`；迁移耗时与内存可接受。
3. 杀进程重启：会话、消息、未读、置顶状态保持。

### B. 聊天与消息
4. 单条发送、失败重试、取消生成、继续生成。
5. 多气泡：一次回复出现多条气泡顺序正确；重启后顺序不变。
6. 编辑消息：改后正文更新、可查看历史版本；撤回后显示提示且搜索不到。
7. 收藏/取消收藏；四类删除（单条/范围/关键词/清空会话）。
8. 会话内搜索命中并可定位原文；空结果有提示。

### C. 多会话
9. 新建会话并切换；生成中切换被拒绝且有提示。
10. 置顶/取消置顶、归档/取消归档、改名、排序。
11. 未读徽标与"全部已读"；进入会话自动已读。
12. 删除会话后消息消失、**记忆/日记仍存在**；主会话不可删除。

### D. 多模态
13. 选图入库：缩略图生成、原图可查看、像素尺寸正确。
14. 设备端 OCR：中文识别可用；断网可识别；识别文本可被全局搜索命中。
15. 多图分析：一次请求携带多张图，结果落库（依赖模型通道）。
16. 语音录制、播放、暂停、进度拖动、重转写、保留原始音频。

### E. 本地模型
17. 下载仅 Wi-Fi 生效；蜂窝需显式允许；暂停/续传；显示占用空间。
18. 导入本地模型文件：校验和核验、来源/版本/许可证展示。
19. 断网后本地推理可用；上下文长度实测值与记录一致。

### F. 人格/关系/日记
20. 核心人格仅用户可改；AI 只能给建议；版本可回看与回退。
21. 外围人格成长提案 → 审批 → 生效 → 回退。
22. 日记一天一篇；用户与 AI 均可编辑且留版本；日记可沉淀为记忆。
23. 关系阶段变更必须用户确认才生效。

### G. 自主与通知
24. 勿扰 23:00–08:00 不主动发；最小间隔 2 小时；每日上限 5 条。
25. 通知三档（完整/简短/隐藏）按类型生效。
26. 一天未开 App 后，下次启动补算整理任务；失败不换模型。
27. 自主度分项开关、暂停、恢复默认、执行记录可查。

### H. 记忆
28. 三套记忆（用户/共同/自我）分别可浏览、筛选、编辑。
29. 记忆合并/纠错留版本；重要修改需确认；可按来源批量删除。
30. 删除会话保留记忆可在记忆页验证。

### I. 备份/迁移/安全
31. 手动备份默认加密；明文导出需二次确认并提示风险。
32. 自动备份与增量备份；保留数量生效；重要版本不被清理。
33. 恢复前预览数量与兼容性、空间检查；失败不破坏现库。
34. AstrBot 全量迁移：聊天/记忆/日记/人格数量与原始包一致；无法识别进入待处理区。
35. 迁移前后指纹校验、回滚可用。
36. Face ID/独立密码、后台锁定、失败次数保护。
37. 删除全部数据：清单 + 二次确认 + 密钥丢失说明。

### J. 交付
38. 签名安装实验版 IPA，确认版本号与更新日志。
39. 诊断包导出已脱敏；存储分类与清理建议可用。

---

## 六、复现与验证命令

```bash
# 单测（GitHub Actions，push 任意分支触发）
git push origin p1.5/b1

# App 层编译检查（手动，macOS）
gh workflow run app-build-check.yml --ref p1.5/b1

# 未签名 IPA（手动，macOS）
gh workflow run build-ipa.yml --ref p1.5/b1
```

本地 Windows 环境**无法**编译 Swift，所有结论以 CI 日志为准。

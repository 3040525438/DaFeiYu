# DaFeiYu V2.0 实施台账

> 性质：**工程活文档**，每个批次完成后必须更新。不是需求文档，也不是验收报告。
> 授权依据：用户 2026-11-15《全权自主开发、完整重构与 AstrBot 数据迁移最终授权书》。
> 最高产品基线：72 项正式产品决策（见《DaFeiYu_V2.0_项目总报告.md》第二章）。
> 更新规则：只追加、不回改历史行；状态变化用新行记录。

---

## 一、授权与硬边界

| 项 | 内容 |
|---|---|
| 技术决策权 | 架构、数据库、模块、选型、接口、测试、重构顺序全部自主，不需逐项请示 |
| 产品决策权 | 归用户；不得删除/弱化/推迟 72 项决策 |
| 实验版 | `DaFeiYuLab` / `com.dafeiyu.lab` |
| 正式版 | `com.dafeiyu.app` **禁止操作** |
| 禁止 | 删除/覆盖 AstrBot 原始包与历史备份、无备份的不可逆数据操作、未授权上传私人数据、未授权费用 |
| 隐私 | 聊天/记忆/日记/人格不得进 Git、不得上传第三方 |

---

## 二、环境能力（决定实施方式）

| 能力 | 状态 | 结论 |
|---|---|---|
| 本地 Swift 工具链 | **无**（Windows，`swift` 不存在） | 无法本地编译 |
| Xcode / xcodebuild | **无** | 无法本地构建 IPA |
| 单测执行 | GitHub Actions `core-tests.yml`（ubuntu + swift:6.2，push 任意分支触发） | 唯一测试通道 |
| iOS 未签名构建 | `build-ipa.yml`（macos-15，`workflow_dispatch` 或 `v*` tag） | 唯一 IPA 通道 |
| 实际产物 | 未签名 IPA，需用户自行签名安装 | 与授权书一致 |

**每批流程**：改代码 → 补测试 → `git commit` → `push p1.5/b1`（或新实验分支）→ 等 `core-tests` → 通过后继续；需要产物时手动触发 `build-ipa`。

---

## 三、批次状态

| 批次 | 内容 | 代码 | 测试 | CI | 备注 |
|---|---|---|---|---|---|
| B0 | 台账建立、环境核查、AstrBot 包独立复核 | 完成 | — | — | 本轮 |
| B1-L1 | 失败原因脱敏展示 | 完成 | 既有覆盖 | 通过 | `b3baf83` |
| B1-L2 | 轮次所有权上提到协调器 | 完成 | App 层 0 测试 | 通过 | `c09faa4` |
| L3/L4/L5 | 未实施 | — | — | — | 待 V2.0 合并处理 |
| V2-M4 | `v4_persona` 迁移 | 完成（`285269c`） | 新增 16 项 | 通过 | 关系档案/指纹/导入/版本扩展 |
| V2-M4b | v4_persona CI 结论 | 完成 | 16 项全绿 | 通过（`285269c`） | core-tests success |
| V2-M5 | `v5_autonomy` | 完成（`e418ee8`） | 新增 10 项 | 通过 | 话题/意图/自主任务/执行记录/自主开关；库层强制 dedupe 唯一与一意图一组 |
| V2-M6 | `v6_character` | 完成（`fd704c5`） | 新增 10 项 | 通过 | 角色/表情/状态/状态历史 + 主动消息治理列 |
| V2-M7 | `v7_meta_backup` | 完成（`fd704c5`） | 新增 10 项 | 通过 | 备份清单/恢复日志/升级记录/附件软删列 |
| V2-M8 | `v8_chat_v2`（追加） | 完成（`e16317c`） | 新增 10 项 | 通过 | 编辑留痕/撤回/收藏/日记与版本/消息与日记 FTS |
| V2-M9 | `v9_astrbot`（追加） | 完成（`e16317c`） | 新增 10 项 | 通过 | 迁移批次/原始 ID 映射/待处理区；不执行导入 |
| V2-BUBBLE | 多气泡协议 | 完成（`77b487d`） | 新增 DFCore 9 项 + DFData 5 项 | 待验证（修复 `7dc81d9`） | `SegmentParser` + `assistantSegmented` 事件 + 事务 B 内追加气泡 + FTS 同步；首次 CI 因参数标签缺失失败，修复提交待跑绿 |
| V2-W2B | 编辑/撤回/收藏、四类删除、会话内搜索、主题存储 | 完成（`c542d26`） | 新增 DFData 13 项 | 待验证（`7dc81d9`） | `GRDBMessageEditingRepository` / `GRDBMessageDeletionRepository` / `GRDBChatSearchRepository` / `GRDBChatThemeStore`；UI 已接编辑弹窗、撤回/收藏、搜索栏、外观设置与批量删除 |
| V2-W2 复核 | W2 两批结论回填 | — | 全绿 | **通过（`7dc81d9`，run 43624297094）** | 多气泡 9+5 项、交互 13 项全部通过；`b892e55` 为纯缩进，同批推送 |
| V2-W3A | 多会话数据层：建/改名/置顶/归档/排序/未读/删除保留记忆 | 完成（`6447435` + 修复 `c7e8d62`） | 新增 DFData 13 项 | 待验证（`c7e8d62`） | `ConversationAdminRepository` + `GRDBConversationAdminRepository`；首轮 CI 暴露四类问题：错误类型被包成 `DFError`、种子会话误标 main、reorder 缺表别名、全部已读只覆盖未读会话，均已修复 |
| V2-W3B | 多会话 UI：列表 / 切换 / 置顶 / 归档 / 改名 / 删除 | 完成（`ec5507b`） | App 层不参与 push CI | 待 `app-build-check` | `ConversationListView.swift`、`ChatViewModel.activate` 统一会话激活链路；生成中禁止切换/删除 |
| V2-W4A | `v10_multimodal` 迁移 | 完成（`d3c1c27`） | 新增 10 项 | 通过 | 附件尺寸/时长/缩略图 + `attachment_texts` + `attachment_text_fts` + `image_analyses`；历史附件一律 NULL，不伪造 |
| V2-W4B | 附件/OCR/多图分析仓储 + 设备端媒体管线 | 完成（`4fa5745`、`67ac713`） | 新增 14 项 | 通过（`4fa5745`） | `GRDBAttachmentRepository` / `GRDBAttachmentTextRepository` / `GRDBImageAnalysisRepository`；`MediaProcessing`（Vision OCR / Speech 端上转写 / 缩略图）+ `AttachmentIngestService` |
| V2-W5A | `v11_local_models` 迁移 + 本地模型注册表 | 完成（`93a2e6c`） | 新增 10 + 10 项 | 通过（`45101ca`） | 模型状态机、下载进度、校验和、实测上下文、运行事件；含 App 公共 init 修复 |
| V2-W5B | 本地模型下载器 + 增量 SHA256 | 完成（`f8a1693`） | 新增 DFCore 3 项 + DFAI 8 项 | **通过（`f8a1693`，run 43640597662）** | `.part` 断点续传、Range 忽略自动重写、校验和缺失拒绝/不一致删文件、仅 Wi-Fi 策略、失败保留断点、删除清理；`SHA256.Hasher` 大文件边读边算 |
| V2-W5C | 本地推理运行时 | **阻塞** | — | — | 需要 llama.cpp/MLX 依赖与网络下载授权；当前仓库无可用推理内核，不以空实现冒充；已记录为 N-18 |
| V2-W6B | 人格成长提案 / 审批 / 版本回退 | 完成（`035c872`） | 新增 `PersonaGrowthServiceTests` 9 项 | **通过（`035c872`，run 43642913413）** | 核心人格写保护、仅 pending 可审批、审批/回退都新建全量版本、指纹按 core / core_outer 重算、回退历史不删除 |
| V2-W6C | 关系档案与阶段确认（提案 → 用户确认 → 落档案；共同经历/转折） | 完成（`3229cb8`） | 新增 `RelationshipServiceTests` 11 项 | **通过（`3229cb8`，run 43643792713）** | 无用户写入不落档案；AI 只能提案，确认/驳回只接受 `user`；提案后档案已变则确认被拒（过期提案）；确认/驳回均留历史；里程碑来源受控（真实互动/用户确认/导入），关联记忆与经历必须存在 |
| V2-W6A | 日记仓储（版本 + FTS + 软删重建） | 完成（`67ac713`） | 新增 10 项 | 通过（`45101ca`） | 一天一篇、每次写入留全量版本、日记全文检索 |
| V2-W7A | 自主闸门（纯逻辑） | 完成（`67ac713`） | 新增 10 项 | 通过（`45101ca`） | 总开关 / 分项 / 跨午夜免打扰 / 最小间隔 / 每日上限 / 下次允许时间 |
| V2-W7A2 | 自主调度服务（五重闸门接线 / 任务队列 / 留痕 / 启动补算 / 通知分档） | 完成（`0fb3f3f` + 修复 `b9e829e`） | 新增 `AutonomyServiceTests` 15 项 + DFCore `AutonomySchedulingTests` 8 项 | **通过（`b9e829e`，run 43644744193）** | 策略落在 `settings` + `autonomy_controls`（分项/暂停）；闸门新增暂停、通知授权、每日预算；每次放行/拦截写 `autonomy_runs`；任务 `dedupe_key` 唯一、认领/结束/过期闭环；启动补算按执行记录判断漏掉的每日任务；通知三档 `full/brief/hidden` 纯函数渲染 |
| V2-W7B | 主动消息治理（收藏 / 不感兴趣 / 减少类似 / 软删除 / 触发原因） | 完成（`8b69a40`） | 新增 `ProactiveMessageServiceTests` 7 项 | **通过（`b9e829e`，run 43644744193）** | 记录/发送/抑制状态机；收藏与反馈分离；删除为软删除并保留触发原因；`explain` 返回意图理由、证据与关联记忆；"不感兴趣"在 30 天窗口内抑制同类 |
| V2-W8A | 记忆仓储（三主体 + 版本 + 来源删除） | 完成（`70102b6`） | 新增 11 项 | 通过（`45101ca`） | `GRDBMemoryRepository`；去重补来源、版本快照、重要度留痕、按来源软删、检索与重建索引 |
| V2-W9A | 备份清单 / 恢复日志 / 保留策略 | 完成（`70102b6`） | 新增 9 项 | 通过（`45101ca`，run 43627768025） | 默认加密、失败不破坏、校验和、保留数量与 safety/verified 保护 |
| V2-W9B | AstrBot 全量导入器（只读副本 / 覆盖校验 / 待处理区 / 回滚） | 完成（`b6ba835`） | 新增 `AstrBotImporterTests` 7 项 | **通过（`b6ba835`，run 43639524117）** | 聊天/记忆/日记/人格/信件/读书笔记/关系账本全量映射；每源行覆盖 = 新增+重复+待处理；源文件 SHA256 前后一致；重复导入幂等；回滚只删本批次实体 |
| V2-APPBUILD | App 层编译检查 | 完成（`f5fdb06`） | `app-build-check` | **通过（run 43628369450）** | 修复两处 App 编译错误：`AttachmentIngestService` 未 `import DFData`；OCR 完成回调里 `request` 需转 `VNRecognizeTextRequest`；`ChatView` 异步删除需 `Task` 包裹 |
| V2-IPA | 未签名 IPA 构建 | 完成（`f5fdb06`） | `build-ipa.yml` | **通过（run 43628905424）** | 产物 `DaFeiYuLab-unsigned-ipa`（2,946,966 字节），已解包核验：`Payload/DaFeiYuLab.app`，`CFBundleIdentifier = com.dafeiyu.lab`，`CFBundleShortVersionString = 0.1.0`；同工作流另有 `DaFeiYu-unsigned-ipa`（正式包名），**仅为构建产物，未签名、未安装、未提交商店** |
| V2-W8B | L1–L7 记忆加工与三主体治理 | 完成（`9d4be4b` + 修复 `b30482a`/`5356ce5`） | 新增 DFCore `MemoryProcessingTests` 18 项 + DFData `MemoryProcessingServiceTests` 13 项 | 修复中（见第四节连续修复记录） | 七层层级元数据与归属矩阵；抽取闸门（证据定位/单轮上限 8/预算/批内去重/确认路由）；L2 情景落库；整理（合并 supersede+链接、事实冲突 disputed+变化事件、冷归档、索引一致性、统计快照）；反思引用校验与自我记忆沉淀；核心人格只提案；L6 图谱派生幂等；L7 工作记忆装配与 24h 快照；三主体主语判定 |
| V2-W9C | 备份加解密、恢复落地、隐私门禁与删除清单 | 完成（`5356ce5` + 修复 `5a43eb1`） | 新增 DFCore `BackupCryptoTests` 8 项 + `PrivacyGateTests` 6 项 + DFData `BackupServiceTests` 7 项 + `PrivacyGateServiceTests` 6 项 | 修复中 | 容器 `DFBK1` + AES-256-GCM（CryptoKit）/测试替身；密钥 Keychain 协议；快照逻辑导出；恢复预检（版本/空间）+ 恢复前安全备份 + 单事务恢复 + 失败回滚 + 三套 FTS 重建；口令加盐哈希、失败冷却、前后台延迟锁定；授权记录；删除清单与逐字确认 |
| V2-W10A | App 层装配：锁屏门禁、备份恢复、隐私、首启向导 | 完成（`b86a0fc` + 修复 `5a43eb1`） | `app-build-check`（每次 App 改动后手动触发） | 修复中 | AppContainer 装配 8 个服务；AppLockController/AppLockView；RootView 接 scenePhase 与隐私设置变更；隐私与安全页、备份与恢复页、删除全部数据页、四步首启向导；Info.plist 增加 Face ID 用途说明 |
| V2-W10B | 语音录制播放与图片理解调用链 | 完成（`7134de9`） | DFCore `ChatTurnImageTests` 4 项 | 待验证 | ChatTurn 支持图片 data URL（旧数据兼容解码），Provider 按 content parts 编码；语音录制/计时/电平/端上转写/回放/填入；图片选图→JPEG 统一→入库→OCR→视觉模型→`image_analyses`→填入 |
| V2-W10C | 审批中心与 AstrBot 迁移界面 | 完成（`bccfb29`） | 依赖既有服务测试 | 待验证 | 记忆提案查询/确认/驳回（确认才写记忆）；人格/关系/记忆三类提案逐条确认；AstrBot 选目录、预演、正式导入、批次、待处理区、回滚 |
| V2-W2.5 | 跨域统一检索 / 消息整理 / 批量归档（D25 / D26 / D51 数据层） | 完成（`4cff077` + 修复 `7fe63c4`/`154eac1`） | 新增 DFCore 8 项 + DFData 31 项（共 39） | **通过（`154eac1`，run 43697137498）** | 首轮 CI 暴露两处：`Row.decodeIfPresent(_:forColumn:)` 被解析到 forKey 重载（改用 `String.fromDatabaseValue`）；v13 用例误断言"最新版本"（改为 `makeMigrator(upTo: .v13_cost_ledger)`）。`v14_message_organization`：`messages.is_important/important_at` + `message_tags`（唯一索引），历史消息默认未标记；`GRDBUnifiedSearchRepository` 四域检索（归档会话仍可检索）；`GRDBMessageOrganizationRepository` 批量收藏/重要/标签（单事务、标签归一化去重、不生成记忆）；`setArchivedBatch`（main 保护、幂等计数）；备份表序加入 `message_tags`；App 层检索/整理界面尚未接线 |
| V2-W4.6 | 附件引用检查与清理（D57 数据层） | 完成（`f64f9c3`） | 新增 DFData 11 项 | **通过（`f64f9c3`，run 43697938991）** | `AttachmentReference` 区分总引用/活引用（已软删消息的关联算陈旧引用）；删除前强校验，被活消息引用默认拒绝，`force` 才解除关联并软删；`unlinkAll`、清理候选、批量清理（跳过被引用、幂等、不刷新首次删除时间）；App 层附件库清理界面未接 |
| V2-W6 | D25/D26/D51/D57 App 界面接通 | 完成（`310a940`） | 新增 DFCore 3 项 + DFData 3 项 | **通过（`310a940`，run 43700580164，3m32s）** | 新增 `GlobalSearchView/ViewModel`（四域分组、摘要来源、消息命中经 `openGlobalSearchHit` 切会话并定位、记忆/日记详情）；`MessageOrganizerView/ViewModel`（收藏/重要/标签筛选 + 批量标记 + 标签增删反馈，明确不写 memories）；`ConversationListView` 批量归档选择态（`setArchivedBatch` + main 保护提示 + 结果回报）；`AttachmentLibraryView/ViewModel`（`library()` 引用统计、活引用/陈旧引用区分、强制解除确认、批量清理未引用）。AppContainer 注入 `unifiedSearch`/`messageOrganization`/`attachmentReferences`。App 编译需手动触发 `app-build-check` |
| V2-W7R | 反思节奏与紧迫度门禁（Shikigami 机制借鉴，独立实现）+ W2-6 生成控制/状态/历史 | 完成（`236cd8c` + 编译修复 `d5cc26c`） | 新增 DFCore `ReflectionCadenceTests` 21 项 + `AutonomyGateRhythmTests` 8 项 + `ChatTurnPhaseTests` 8 项；DFData `AutonomyServiceRhythmTests` 5 项 + `MessageDateJumpTests` 4 项 | **通过（`d5cc26c`，run 43703524689）**；首轮 `236cd8c` run 43703046673 编译失败（Double/Int 比较），已修复 | ①`ReflectionCadence`：严格 JSON 键集（多键/少键/类型错/未知枚举全部降级且不崩溃）、urgency 夹取 0–1、`next_reflection_in` 夹取 60–3600 秒、重启按"上次更新时间 + 间隔"续算、`CadenceSignals`（60 分钟窗口 / 最近 20 样本 / isQuick / isSlow）、`ReflectionRhythm` 只收紧不放宽；②`AutonomyGate.evaluate` 新增可选 `urgency/speakReason/cadence/urgencyThreshold`，不传时行为与原先一致；`AutonomyService.evaluateSend`、`ProactiveIntentService.dispatch` 透传并写 `autonomy_runs`；③修复编排器提示词缺少本轮用户输入（历史只含已关闭组），重试场景不重复追加；④D49：`continueTurn` 契约（隐藏指令 `origin=system`，界面按 `isHiddenInstruction` 过滤）、协调器 `PauseGate` 暂停闸门 + 暂停/继续事件、界面暂停/继续/续写；⑤D52：`ChatTurnPhase` 七态（等待/思考/生成/暂停/完成/失败/停止）+ 非法跃迁拦截；⑥D56：`page(in:around:limit:)` 日期跳转（协议默认兜底 + GRDB 直查）、分页游标、加载更早、逐页定位。**注意：暂停只挂起界面消费，模型请求不取消（真实边界，已写入代码注释）** |
| V2-W7T | D26 标签全局重命名（I-01） | 完成（`bcc6ec7`） | 新增 DFData 5 项 | **通过（`bcc6ec7`，run 43703893472，2m52s，DFCore/DFAI/DFData 全绿）** | `renameTag(_:to:at:)`：单事务 `UPDATE OR IGNORE` + 清理旧行；新旧标签同一归一化口径；与已存在标签合并时只保留一行；空/超长新标签分别抛 `emptyTag`/`tagTooLong`；界面标签胶囊右键「重命名标签…」弹窗并回报影响条数 |



---

## 四、技术决策记录（ADR）

| 编号 | 决策 | 理由 | 日期 |
|---|---|---|---|
| ADR-01 | 迁移只能在 `MigrationID` **末尾追加**，不改已有 7 级 | 既有 R6 冻结口径，历史库兼容 | 2026-11-15 |
| ADR-02 | 新表优先放入既有的 v4–v7 语义槽位，聊天/迁移类新增追加为 v8/v9 | 保持序列语义清晰 | 2026-11-15 |
| ADR-03 | 每个迁移必须含：前置断言 + 迁移前指纹 + 哨兵读写 + 迁移后校验 + `schema_meta` 写入 | 沿用 `V3Chat` 已验收模式 | 2026-11-15 |
| ADR-04 | 迁移不得修改历史行内容与状态，只做 DDL 与回填必要默认值 | 保护 1.7 万条历史数据 | 2026-11-15 |
| ADR-05 | AstrBot 迁移使用独立工作副本，原始包只读 | 授权书 §14.2 | 2026-11-15 |
| ADR-06 | 5121 条记忆一律进 `shared` 暂存 + `pending` + 权重 0.6 | 72 项决策与 M-43~M-47 | 2026-11-15 |
| ADR-07 | L2–L7 图谱一律由新系统对真实数据重新生成，不伪造恢复 | 授权书 §4 | 2026-11-15 |
| ADR-08 | **本地模型运行阶段暂缓**：N-18/N-01、下载/导入/加载/推理、本地上下文实测与离线闭环全部不投入；D01/D02/D05/D58/D71 中依赖本地推理的部分标"暂缓/部分完成"，不得标完成 | 本阶段以云端模型真实闭环为主；现有注册表、迁移、测试、接口与扩展点**保留不删** | 2026-11-15 |
| ADR-09 | 开源借鉴边界：只借鉴**设计与机制**并独立实现，不复制 AGPL-3.0 代码；不引入 Python/Electron/FastAPI 作为 iOS 运行依赖；不新增付费服务；核心人格不得被模型自动改写，重要关系变化须用户确认 | 许可证义务 + 授权书 §5 硬边界 | 2026-11-15 |
| ADR-10 | **暂停语义 = 只挂起界面消费**：`PauseGate` 扣住已到达的增量，不取消模型请求；恢复后从断点继续；用户要真正结束本轮必须点"停止"（走取消链路）。不对外宣称"暂停即停止模型计算" | iOS 无法安全挂起/续传上流网络请求；如取消再续需重放开组，会破坏"保留已生成内容 + 可续写"的契约。真实边界写入代码注释与交付报告 | 2026-11-15 |
| ADR-11 | 反思节奏（urgency / cadence / next_reflection_in）只在**纯逻辑层**判定并作为 `AutonomyGate` 的**附加收紧条件**，不替代既有五重闸门；不传参数时行为与原先完全一致 | 保证既有 10+ 项闸门测试不变，同时把 Shikigami 的机制接进真实投递路径 | 2026-11-15 |

---

## 五、AstrBot 数据基线（独立复核结果）

| 数据 | 实测 | 位置 |
|---|---|---|
| 压缩包 | 84,671,865 字节 / 833 文件 | `her-2026-11-03.zip` |
| 聊天记录 | 17,183 条（user 14,109 / assistant 3,074） | `data/plugin_data/chat_memory/chat_memory.db` |
| 真实文本 | 6,095 条（约 122,676 字符） | 同上 |
| 系统通知 | 10,992 条，内容多为 `[系统通知]` | 同上 |
| 图片/文件/图文 | 92 / 4 / 2 条（**本体缺失**） | 同上 + `chat_memory_media_archive` |
| 长期记忆 | 5,121 条（chat 4,967 / diary 124 / fact 30）+ FTS 5,121 | `diary/memory.db` `mem` |
| 日记 | 10 天（10-24~11-02）+ INDEX + FACTS | `diary/` |
| 人格 | 1 条，`persona_id=whale`，system_prompt 921 字 | `data/data_v4.db` `personas` |
| 关系账本 | 133 条，score=111 | `companions.json` |
| 信件/书籍 | 3 / 2 | `letters/` `books/` |
| API key | 已清空 | `cmd_config.json` |
| 异常 | 33 条记忆 `day` 非法；9 条撤回；图谱表为空 | 见索引文档 |

工作副本：`E:\temp_20261113_01\_astrbot_review`（只读分析用，改动前先复制）。

---

## 六、已知问题与阻塞

| 编号 | 问题 | 影响 | 处理 |
|---|---|---|---|
| K-01 | 本地无 Swift/Xcode | 每批只能靠 CI 验证 | 提高代码审查密度，小步提交 |
| K-02 | 聊天附件本体缺失 | 附件功能无法用真实数据验收 | 迁移时标记"待补充"，不伪装完成 |
| K-03 | 表情包未随包 | 同上 | 独立核查，不擅自从网络下载 |
| K-04 | App 层 0 测试 | UI/协调器无回归保护 | V2 中新增 App 层测试 target |
| K-05 | 工作区两文件 CRLF/LF 差异 | `git status` 显示脏但 diff 为空 | 提交时不包含无关换行改动 |
| K-06 | 历史图谱表为空 | 不能声称"已恢复图谱" | 由新系统重新生成并标注派生 |

---

## 七、恢复说明（会话中断 / 上下文丢失）

1. 读本台账第三节确认最后完成批次。
2. `git log --oneline -10` 与 `git status` 确认实际提交与未提交改动。
3. 若最后一批已 push 但 CI 未过：先修 CI，不叠加新功能。
4. 若工作区有未提交改动：先审查 diff，再决定继续或回退（回退前必须备份）。
5. 从第三节第一个"未开始"批次继续，不重头再来。

---

## 八、待办体系与需求追溯（唯一任务清单来源）

> 结论：10 项待办**不是**完整开发清单，只是工作包。完整任务量为 **10 个工作包 / 68 个子任务**，逐项含完成标准、代码证据、测试证据。

| 项 | 内容 |
|---|---|
| 追溯文档 | 《DaFeiYu_V2.0_需求追溯矩阵与任务分解.md》 |
| 覆盖对象 | 72 项正式决策（逐条）+ 后续补充需求 + 历史 193+84 条映射 |
| 工作包 | W1 数据底座 / W2 聊天交互 / W3 多会话 / W4 多模态 / W5 模型系统 / W6 人格关系日记角色 / W7 自主陪伴 / W8 记忆七层 / W9 备份迁移安全 / W10 交付验证 |
| 状态口径 | 已实现有证据 / 已实现待验证 / 部分实现 / 正在开发 / 尚未开发 / 技术阻塞 / 需要用户确认 |
| 证据等级 | E0 无证据 → E1 代码 → E2 单测 → E3 CI → E4 真机 |

**当前覆盖率（R1 审查）**：72 项决策中，达到"完整闭环 E3"的为 0 项；**部分实现 27 项**；**尚未开发 44 项**；**技术阻塞 1 项**（D02 需真机实测）；待确认 2 项（G-06/G-07）。详细逐条见追溯文档第三章。

**执行原则**：按 W1 → W10 顺序推进，但允许并行条件已就绪的子任务；每个子任务单独提交、单独 CI，不合并批次。

---

## 九、变更记录

| 日期 | 变更 |
|---|---|
| 2026-11-15 | 首次建立；完成 B0 环境核查与 AstrBot 数据独立复核；启动 V2-M4 |
| 2026-11-15 | V2-M4 代码完成并推送 `285269c`；建立《需求追溯矩阵与任务分解》（72 项逐条 / 10 工作包 / 68 子任务），确认原 10 项待办仅为工作包 |
| 2026-11-15 | `285269c` 的 core-tests 结论回填：success（V2-M4b 关闭） |
| 2026-11-15 | V2-M5 代码完成：`V5Autonomy.swift` + `MigrationV5Tests`（V5-01~V5-10）；修复两处 CI 失败（缺少 `try`；`MigrationID.allCases.last` 误含未发布的 v6/v7），新增 `Migrations.latest` 作为已发布版本单一事实源 |
| 2026-11-15 | `e418ee8` 的 core-tests 通过（V2-M5 关闭）；V2-M6 代码完成并推送 `49bd099`（v6_character，门禁扩至 52 项） |
| 2026-11-15 | V2-M6 修复 `proactive_messages` 无 `created_at` 的索引列错误；V2-M7 完成（`fd704c5`，门禁 61 项），v6+v7 一并通过 CI |
| 2026-11-15 | V2-M8（`78abadf`）与 V2-M9（`e16317c`）通过 CI：迁移链 v1→v9 全线可测，门禁 81 项，`expectedMigrations=9` |
| 2026-11-15 | W2 代码两批完成：多气泡协议（`77b487d`）+ 编辑/撤回/收藏/四类删除/搜索/主题（`c542d26`）；首次 CI 因 `MessageIndexer.index` 缺少 `db:` 参数标签失败，修复提交 `7dc81d9`；结论待回填 |
| 2026-11-15 | `7dc81d9` core-tests 通过（run 43624297094），W2 关闭；推送 `b892e55` |
| 2026-11-15 | W3 数据层完成（`6447435`），首轮 CI 失败（4 类原因见第三节），修复提交 `c7e8d62`；W3 UI 完成（`ec5507b`） |
| 2026-11-15 | 启动 W4：新增 `v10_multimodal` 迁移（附件尺寸/时长/缩略图 + `attachment_texts` + `attachment_text_fts` + `image_analyses`），`Migrations.latest` 前移；同时把 `MigrationV9Tests` 锁定到 v9，避免被新版本牵连 |
| 2026-11-15 | W4/W5/W6/W7/W8/W9 数据层全部合并：`v10_multimodal`、`v11_local_models`、附件/OCR/多图仓储、本地模型注册、日记、自主闸门、记忆、备份清单；`Migrations.latest = .v11_local_models` |
| 2026-11-15 | 连续修复 CI：字典/枚举关键字 `self`、DFCore 记录类型缺 `public init`、`DiaryUpsert` 参数顺序、错误类型被包装、保留策略预期、v9/v10 台账断言锁定版本。最终 `45101ca` core-tests 通过 |
| 2026-11-15 | `app-build-check` 首次失败（缺 `import DFData`、OCR request 类型、异步 delete 未包 `Task`），修复后 `f5fdb06` **App 层编译通过**（run 43628369450） |
| 2026-11-15 | 生成《DaFeiYu_V2.0_交付状态与验收报告.md》，如实列出已完成证据与 N-01～N-17 未完成项；触发未签名 IPA 构建 |
| 2026-11-15 | 注意：`app-build-check` 与 `build-ipa` 均为 macOS 计费通道，只在批次收口时触发 |
| 2026-11-15 | 修复 `MemoryProcessingService.approveProposal`：异步 `read` 返回 `Row?` 不满足 Sendable 被推断成 Void（`ec94fb4`），改为闭包内解码；随后修正局部变量与记忆记录同名（`a231307`） |
| 2026-11-15 | 新增 W8-3 记忆抽取闭环（`df01164`）：`MemoryExtractionPrompt/Parser`（提示词 + 围栏 JSON 解析 + 证据定位 + 去重键）、`MemoryExtractionCoordinator`（真实 provider 流式输出 → 筛查 → 入库）、编排器 `onTurnCompleted` 后置钩子（非结构化任务，不阻断聊天）、AppContainer 接线与 `memory.extraction.enabled` 开关；新增 DFCore 8 项 + DFOrchestration 5 项测试 |
| 2026-11-15 | 修复备份恢复 `NOT NULL constraint failed: conversations.title`（`554e678`）：`Row` 按列名取值在部分版本返回 Optional，`as? DatabaseValue ?? .null` 会把整列写成 NULL；改为按列序号映射 `Row` 的 `DatabaseValue` 集合并加宽度校验 |
| 2026-11-15 | 新增 W10-3 诊断与存储（`e7add8b`）：`DiagnosticRedactor`（密钥/Bearer/邮箱/手机号/长哈希/个人目录）、`DiagnosticExporter` Markdown、`StorageUsage` 分类与空间预警、`DatabaseStats` 只读计数、`DiagnosticsView` 分享诊断包；新增 DFCore 7 项测试 |
| 2026-11-15 | 修复 W10-3 App 编译错误：IntegrityReport.isHealthy 字段名、`??` 右侧 await 的 autoclosure 限制、ImageUnderstandingSheet 未处理 throw；同批加入本地模型管理页与 NWPathMonitor 仅 Wi-Fi 门（813b0ad） |
| 2026-11-15 | 15eec68 core-tests 通过；app-build-check（run 43677825319）App 层编译通过 |
| 2026-11-15 | 新增 N-07/N-08 接线（6c33f4f）：BackgroundRefreshService（BGTaskScheduler 注册 + 后台补算 + 过期清理）、ProactiveNotificationService（授权/三档渲染/投递/撤销/清空）、通知设置页；Info.plist 增加 UIBackgroundModes=fetch 与 BGTaskSchedulerPermittedIdentifiers；顺带补 AudioPreviewPlayer.resume() |
| 2026-11-15 | build-ipa（run 43678102338）成功：正式版与实验版未签名 IPA；下载实验版产物核验 CFBundleIdentifier=com.dafeiyu.lab、BGTaskSchedulerPermittedIdentifiers、UIBackgroundModes=fetch；明确未签名、未安装、非完整 V2.0 |
| 2026-11-15 | 新增 W8-2 日记沉淀（ba5ede6，测试修复 87e19b9）：DiaryMemoryService 正文首段→情景候选→既有筛查/去重/提案→回填 memory_id；DiaryRepository.attachMemory 只回填不追加版本；新增 DFData 5 项测试 |
| 2026-11-15 | 新增 D34 日记结构化（e930a44）：`v12_diary_structure` 给日记与版本表追加 `shared_experience/observation/feeling/relationship_change/relationship_change_confirmed`，历史行只给默认值、不补写；结构化字段纳入 FTS 与版本快照；新增 `Features/Diary/DiaryView.swift`、`DiaryEditorView.swift`（列表/新建/编辑/软删/沉淀记忆），空间页接入；`Migrations.latest=.v12_diary_structure`、门禁 96 项 |
| 2026-11-15 | 修复 CI 类型检查超时（94a26e4）：`BackupService` 日记 FTS 拼接拆成循环，`GRDBDiaryRepository` 结构化字段抽 `structuredValues`；重新触发 core-tests 与 app-build-check |
| 2026-11-15 | 修复 App 编译缺 `import DFData`（e68d70b）；core-tests run `43680552034` 通过、app-build-check run `43680140639` 通过。期间 `MigrationV2Tests.testT13_MigrationPerformance` 在慢机器上曾 8.06s > 8s 失败，重跑通过，属既有时限抖动，未改阈值 |
| 2026-11-15 | 新增 N-14 更新日志页（b00227c）：`SettingsView` → `ChangelogView`，展示真实版本号/构建号/schema 版本与 10 个已交付批次，标注未签名开发版；app-build-check run `43681288275` 通过 |
| 2026-11-15 | 迁移性能门禁修正（ffb25aa）：CI 再次出现 8.85s > 8s 误报，`testT13_MigrationPerformance` 阈值放宽到 20s（保留数量级回归拦截）；core-tests run `43681647964` 通过 |
| 2026-11-15 | build-ipa（run 43681937056，`ffb25aa`）成功：正式版 + 实验版未签名 IPA，包含 D34 日记界面与 N-14 更新日志；仍未签名、未安装，不构成完整 V2.0 |
| 2026-11-15 | 新增 D41 备份外部导出（c3d92de）：`BackupCenterView` 每份可用备份支持"导出"，`fileExporter` 原样导出已加密容器；`BackupService.fileURL(for:)` 定位沙盒文件；新增 1 项导出容器测试；core-tests run `43682798110`、app-build-check run `43682811219` 通过 |
| 2026-11-15 | 开源借鉴核验（Shikigami-Protocol）：仓库实际源码目录为 `src/agent`、`src/api`、`src/commands`、`src/config`、`src/context`、`src/core`、`src/engines`、`src/llm`（GitHub 树接口返回内容被截断，未逐一核验全部路径；不以 README 结论代替源码）。已读实现：`src/core/reflection.py`（周期性"内心独白"，严格 JSON 键集合校验、`urgency` 夹取 0–1、解析失败回退默认、`next_reflection_in` 自适应下轮间隔、重启后续算剩余等待、`speak_reason` 枚举，urgency 交给 ASE 阈值决定是否主动开口）；`src/context/cadence_tracker.py`（按 profile 记最近 20 条时间戳，输出 10 分钟条数/平均间隔/最近间隔/快慢标记，纯内存）。结论：只借鉴机制（自适应反思间隔、urgency 门禁、节奏信号、严格 schema 校验），不复制 AGPL-3.0 代码，见 ADR-09 |
| 2026-11-15 | 新增 V2-W6：D25/D26/D51/D57 App 界面接通真实数据层（`310a940`，core-tests run `43700580164` 通过）；复用既有 Repository/Service，不新增迁移；D26 明确不写 memories；D57 删除前引用校验全部走数据层服务。新增 `AttachmentLibraryItem` + `library()` 数据源，标签长度规则收敛到 `MessageTagRules` |
| 2026-11-15 | build-ipa（run 43683193067，`c3d92de`）成功：正式版 + 实验版未签名 IPA，含 D34、N-14、D41；仍未签名、未安装，不构成完整 V2.0 |
| 2026-11-15 | 新增 N-20 意图生成与调度接线（`08dd9cd`）：`ProactiveIntentService` 调模型严格 JSON → 证据逐字校验 → `conversation_intents` → `evaluateSend` 五重闸门 → 写会话（origin=proactive）+ `proactive_messages` + 通知；`ProactiveScheduler` 按久未说话/免打扰/间隔/日上限排任务；接入启动与后台唤醒；新增 19 项测试 |
| 2026-11-15 | 新增 D09 自动备份调度（`99b8ba0`）：`BackupSchedulePolicy` + `BackupScheduleService`（每日完整/变更增量/1h 最小间隔/空库跳过/失败不推进时间戳），接入启动与后台唤醒；新增 9 项测试 |
| 2026-11-15 | 新增 N-18 前置模型体检（`99b8ba0`）：GGUF/GGML 文件头识别 + 流式 SHA-256 + 大小/登记值校验，6 项测试；**推理内核仍未接入**，仍是 V2.0 完整性硬缺口 |
| 2026-11-15 | 扩展 D41（`99b8ba0`）：备份中心新增外部位置授权（安全作用域书签）+ 复制到外部 + 大小校验；厂商 OAuth 云盘仍未接入 |
| 2026-11-15 | 本批 CI（`08dd9cd`）：core-tests run `43686013429` 通过、app-build-check run `43686026790` 通过；期间修正 GRDB 可选列解码与测试快照取值 2 处编译错误 |
| 2026-11-15 | build-ipa（run 43686373090，`08dd9cd`）成功：正式版 + 实验版未签名 IPA，含 N-20/D09/N-18 前置/D41 外部目录；仍未签名、未安装，不构成完整 V2.0 |
| 2026-11-15 | 新增 D06 人格文件导入（`6896013`）：`PersonaFileParser`（JSON sections/items/数组、Markdown 标题+列表、TXT [段落]+分隔符，去重/200 条截断/代码块跳过）、`PersonaFileImportService`（比对 `outerItems()`，只生成待审批提案，核心人格不受影响；`PersonaRepository.ensureOuterPersona` 幂等创建外围人格并开启成长）、`PersonaImportView`（空间页入口、预览、跳审批中心）；新增 DFCore 12 项 + DFData 6 项测试 |
| 2026-11-15 | 新增 D42 从文件导入备份（`6896013`）：`BackupService.importBackupFile` 识别 DFBK1 容器/明文 JSON，本机密钥解密校验，拒绝未知表与格式不符，导入只登记清单不自动恢复；`BackupCenterView` 增加「从文件导入备份…」；新增 4 项备份导入测试 |
| 2026-11-15 | 新增 D18 日记触发人格提案（本批待推送）：`DiaryPersonaProposalService` 把日记「观察 / 关系变化」转成外围人格待审批提案，正文与感受不直接变人格，证据保留日记 id/日期/原文，同内容已有条目或 pending 提案时跳过；日记编辑页增加「从日记提炼人格提案」；新增 5 项测试 |
| 2026-11-15 | 本批 CI 修复：① `GRDBPersonaRepository.ensureOuterPersona` 版本快照空数组改为 `[Any]()`（`a5dc50f`）；② `BackupService.importBackupFile` 的安全作用域访问仅 Darwin 调用，Linux CI 直接读文件（`724e5b7`）；③ `core-tests` 的 DFData 步骤容器默认 shell 为 sh，`PIPESTATUS` 取不到导致步骤恒失败，显式 `shell: bash` 并去掉无效的 ci-logs 推送（`03ad2cd`）。core-tests 于 `03ad2cd` 通过（DFCore/DFAI/DFData 全绿） |
| 2026-11-15 | 待办：本批三条 App 侧入口（PersonaImportView、BackupCenterView 从文件导入、DiaryEditorView 提炼按钮）仅完成源码接线，尚未跑 `app-build-check`/`build-ipa`，需手动触发 macOS 通道验证编译 |
| 2026-11-15 | 新增 D10 预算与成本控制（`506d3d6`）：① `DFCore/Budget/Budget.swift` 定义 `CostKind`（confirmed/estimated/unavailable）、`ModelPricing`、`TokenEstimator`、`BudgetLimits`/`BudgetSpend`/`BudgetGuard` 纯函数；② v13 迁移 `cost_ledger`（CHECK 约束禁止 unavailable 写 0，索引 day/created，哨兵 + 行数不变 + schema_meta 门禁 99 项）；③ `BudgetService` 在单个写事务内完成"读当日聚合 + 判定 + 预占"，提供 settle/fail/cancel 与审计记录，未知费用按 `unknownReserveYuan` 保守计入，按本地 `day_key` 跨日重置；④ `AutonomyGate` 新增预算上下文（每日/单次/自主预算 + 未知保守口径），旧 `dailyBudgetYuan` 也改用有效自主花费；⑤ 聊天编排请求前预占、流内捕获 usage、成功/失败/取消各结算一次，预算不足以 `budget_blocked` 收尾且不发请求；⑥ `ProactiveIntentRunner` 用真实预算预占/结算，闸门改传真实花费快照；⑦ Provider 请求附带 `stream_options.include_usage`；⑧ 设置页新增 `BudgetCenterView`（上限/单价/今日折算/最近 30 条记录）；新增 32 项测试（BudgetTests 13、BudgetServiceTests 12、ChatOrchestratorBudgetTests 4、MigrationV13Tests 3） |
| 2026-11-15 | D10 CI：首次 run 43692968151 因单测可选值断言编译失败；修正后 run 43693216408 暴露 `newConversation` 分项默认关闭导致预算用例误判；同时把 `core-tests` 的 DFCore/DFAI 步骤改为 bash + 失败注解（`1b35de2`），使 Linux 容器错误可公开读取。最终 `e99f888` core-tests run `43694603302` 通过（DFCore/DFAI/DFData 全绿） |
| 2026-11-15 | 待办：D10 设置页 `BudgetCenterView` 与编排/自主接线仅完成源码与 Linux 单测，尚未跑 `app-build-check`/`build-ipa`（macOS 通道需手动触发） |
| 2026-11-15 | 新增 V2-W7R（`236cd8c`）：把 Shikigami 的反思机制落成 Swift 独立实现——`ReflectionCadence`（严格 JSON 键集 / urgency 夹取 / 间隔夹取 / 重启续算 / 节奏信号 / 说话阈值）与 `AutonomyGate` 可选联动参数；同时完成 W2-6 的 D49（暂停闸门 + 续写契约 + 界面按钮）、D52（`ChatTurnPhase` 七态）、D56（分页游标 + 加载更早 + 日期跳转 + 逐页定位）。**顺带修复编排器提示词缺失本轮用户输入**：上下文只来自已关闭组，之前模型实际看不到刚发送的这条（重试场景已做去重）。ADR-10 记录暂停的真实语义 |
| 2026-11-15 | 三份项目文档（需求矩阵 / 交付报告 / 实施台账）已复制进仓库 `DaFeiYu/Docs/`，仓库外原始目录 `大肥鱼-V1.1-记忆与自主系统设计` 保留并同步更新，避免文档只存在于仓库外 |
| 2026-11-15 | **阻塞（未解除）**：`app-build-check` / `build-ipa` 都是 `workflow_dispatch`，需要 GitHub 令牌；本机未安装 `gh`，也无 `GH_TOKEN`/`GITHUB_TOKEN`，因此**本批未能触发 App 编译**。App/Features 改动（`ConversationCoordinator`、`ChatView`、`ChatViewModel`）只经人工审读，未经编译器验证，不得记为"编译通过" |

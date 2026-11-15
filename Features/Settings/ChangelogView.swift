import SwiftUI
import DFCore

/// 版本记录：只展示真实做过的能力批次，不伪造发布日期与对外版本。
struct ChangelogEntry: Identifiable {
    let id: String
    let title: String
    let items: [String]
}

@MainActor
struct ChangelogView: View {
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                versionCard

                ForEach(Self.entries) { entry in
                    entryCard(entry)
                }

                footnote
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(alignment: .top) { pageBackground }
        .navigationTitle("更新日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(DFColor.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    // MARK: - 当前版本

    private var versionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("当前版本")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DFColor.ink)
                Spacer()
                Text(appVersion)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DFColor.primaryDeep)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(DFColor.primarySoft, in: Capsule())
            }

            infoRow("构建号", buildNumber)
            infoRow("运行环境", container.environment.displayName)
            infoRow("数据库结构", container.schemaVersion)
        }
        .padding(14)
        .background(DFColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous)
                .stroke(DFColor.hairline, lineWidth: 1)
        )
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(DFColor.inkMuted)
            Spacer()
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(DFColor.ink)
                .multilineTextAlignment(.trailing)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        return "v\(version)"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    // MARK: - 记录

    private func entryCard(_ entry: ChangelogEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DFColor.ink)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(entry.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Circle()
                            .fill(DFColor.primary.opacity(0.55))
                            .frame(width: 4, height: 4)
                            .padding(.top, 5)
                        Text(item)
                            .font(.system(size: 11))
                            .foregroundStyle(DFColor.inkMuted)
                            .lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DFColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous)
                .stroke(DFColor.hairline, lineWidth: 1)
        )
    }

    private var footnote: some View {
        Text("以上为内部开发批次的真实记录；当前产物是未签名开发版，尚未对外发布，也没有对外版本号。")
            .font(.system(size: 9))
            .foregroundStyle(DFColor.inkMuted.opacity(0.85))
            .lineSpacing(2)
            .padding(.top, 4)
    }

    private var pageBackground: some View {
        ZStack(alignment: .top) {
            DFColor.canvas
            DFSoftGlow()
                .frame(height: 200)
                .clipped()
        }
        .ignoresSafeArea()
    }

    // MARK: - 数据

    /// 按真实交付批次倒序排列（同一开发期内多次提交，不编造发布日期）
    static let entries: [ChangelogEntry] = [
        ChangelogEntry(
            id: "d34",
            title: "日记结构化与日记界面（D34）",
            items: [
                "v12 迁移为日记与版本快照增加共同经历、观察、感受、关系变化与确认标记",
                "历史日记只给默认值，不补写、不改动已有正文",
                "空间页新增日记列表与编辑页：新建、编辑、软删、沉淀为长期记忆"
            ]
        ),
        ChangelogEntry(
            id: "w8-2",
            title: "日记沉淀（W8-2）",
            items: [
                "日记正文首段生成情景记忆候选，证据必须逐字来自正文",
                "沿用既有筛查/去重/提案治理，沉淀后回填 memory_id，不重复抽取"
            ]
        ),
        ChangelogEntry(
            id: "n07-n08",
            title: "后台刷新与通知（N-07 / N-08）",
            items: [
                "BGTaskScheduler 注册后台刷新，唤醒时执行过期清理与任务补算",
                "本地通知三档渲染、投递与撤销，附通知设置页"
            ]
        ),
        ChangelogEntry(
            id: "w5",
            title: "本地模型管理（W5）",
            items: [
                "模型登记：来源、大小、SHA-256、规格、许可证",
                "下载与断点续传、校验和核验、仅 Wi-Fi 下载门、删除文件保留登记"
            ]
        ),
        ChangelogEntry(
            id: "w10-3",
            title: "诊断与存储（W10-3）",
            items: [
                "诊断文本脱敏、Markdown 诊断包导出",
                "存储分类与空间预警、数据库只读计数"
            ]
        ),
        ChangelogEntry(
            id: "w4",
            title: "多模态数据层（W4）",
            items: [
                "附件宽高/时长/缩略图、OCR 与端上转写文本、多图分析记录",
                "三套全文索引与恢复后重建"
            ]
        ),
        ChangelogEntry(
            id: "w9",
            title: "备份、隐私与迁移（W9）",
            items: [
                "AES-256-GCM 加密备份、恢复预检与单事务恢复",
                "锁屏与独立密码、六类隐私授权、逐字确认的删除清单",
                "AstrBot 全量导入、预演、待处理区与回滚"
            ]
        ),
        ChangelogEntry(
            id: "w6-w8",
            title: "人格、关系与记忆（W6 / W8）",
            items: [
                "核心人格写保护与版本回退；外围成长提案审批",
                "关系阶段提案需用户确认，历史与里程碑留痕",
                "L1–L7 记忆加工、候选筛查、去重与冲突处理"
            ]
        ),
        ChangelogEntry(
            id: "w2-w3",
            title: "聊天与多会话（W2 / W3）",
            items: [
                "多气泡协议、编辑留痕、撤回、收藏、四类删除、会话内搜索",
                "多会话建改删、置顶、归档、未读；删除会话保留记忆与日记"
            ]
        ),
        ChangelogEntry(
            id: "migrations",
            title: "迁移底座（v1–v12）",
            items: [
                "规范迁移顺序、台账摘要与必需对象门禁",
                "门禁 96 项；迁移失败整体回滚并降级为只读，等待用户重试"
            ]
        )
    ]
}

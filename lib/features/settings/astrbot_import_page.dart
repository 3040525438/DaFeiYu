/// AstrBot 数据导入页：选择 AstrBot 数据根目录 → 自动探测标准相对路径 →
/// 预演（dry-run，整体回滚只留报告）→ 覆盖式正式导入。
///
/// 源文件只读、只增不覆盖既有数据、每行有归属、可回滚——这些硬约束都在
/// [AstrBotImporter] 内部实现；本页负责选目录、把探测结果如实呈现、二次确认。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../app_container.dart';
import '../../core/import/astrbot_import.dart';

/// AstrBot 标准数据布局（相对根目录）
const List<(String, String)> _probeLayout = <(String, String)>[
  ('聊天库', 'data/plugin_data/chat_memory/chat_memory.db'),
  ('长期记忆库', 'diary/memory.db'),
  ('人格库', 'data/data_v4.db'),
  ('日记目录', 'diary'),
  ('信件目录', 'letters'),
  ('读书笔记目录', 'books/notes'),
  ('关系账本', 'data/plugin_data/astrbot_plugin_private_companion/companions.json'),
  ('主配置（只留档）', 'data/cmd_config.json'),
];

class AstrBotImportPage extends StatefulWidget {
  const AstrBotImportPage({super.key});

  @override
  State<AstrBotImportPage> createState() => _AstrBotImportPageState();
}

class _AstrBotImportPageState extends State<AstrBotImportPage> {
  String? _rootPath;
  final Map<String, bool> _probed = <String, bool>{};
  bool _working = false;
  String? _report;

  Future<void> _pickRoot() async {
    final path = await FilePicker.platform.getDirectoryPath(dialogTitle: '选择 AstrBot 数据根目录');
    if (path == null) return;
    setState(() {
      _rootPath = path;
      _probed.clear();
      _report = null;
    });
    await _probe();
  }

  /// 探测标准布局中实际存在的数据源
  Future<void> _probe() async {
    final root = _rootPath;
    if (root == null) return;
    final probed = <String, bool>{};
    for (final (String label, String rel) in _probeLayout) {
      final absolute = '$root/$rel'.replaceAll('/', Platform.pathSeparator);
      probed[label] = FileSystemEntity.typeSync(absolute) != FileSystemEntityType.notFound;
    }
    if (!mounted) return;
    setState(() => _probed..clear()..addAll(probed));
  }

  /// 从探测结果构造源路径（缺失的源传 null）
  AstrBotSourcePaths? _buildSources() {
    final root = _rootPath;
    if (root == null || _probed.values.every((bool exists) => !exists)) return null;
    String? abs(String rel) {
      final p = '$root/$rel'.replaceAll('/', Platform.pathSeparator);
      return FileSystemEntity.typeSync(p) == FileSystemEntityType.notFound ? null : p;
    }

    return AstrBotSourcePaths(
      chatMemoryDatabase: abs('data/plugin_data/chat_memory/chat_memory.db'),
      longTermMemoryDatabase: abs('diary/memory.db'),
      personaDatabase: abs('data/data_v4.db'),
      diaryDirectory: abs('diary'),
      lettersDirectory: abs('letters'),
      bookNotesDirectory: abs('books/notes'),
      companionLedgerJson: abs('data/plugin_data/astrbot_plugin_private_companion/companions.json'),
      configJson: abs('data/cmd_config.json'),
    );
  }

  /// 预演：完整跑映射与校验后整体回滚，只留批次报告
  Future<void> _dryRun() async {
    await _run(isDryRun: true);
  }

  /// 正式导入（覆盖式：先回滚上一次导入的数据）
  Future<void> _confirmRealRun() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('正式导入 AstrBot 数据？'),
        content: const Text(
          '导入采用覆盖式口径：\n\n'
          '1. 先回滚上一次导入写入的数据，避免重复累积；\n'
          '2. 源文件全程只读；\n'
          '3. 每一行源数据都会落到「新增 / 重复 / 待处理」之一，不会静默丢弃。\n\n'
          '导入完成后可在记忆库与聊天页看到导入的数据。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('开始导入'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _run(isDryRun: false);
  }

  Future<void> _run({required bool isDryRun}) async {
    final container = context.read<AppContainer>();
    final sources = _buildSources();
    if (sources == null) {
      setState(() => _report = '未找到任何可导入的数据源，请确认目录结构');
      return;
    }
    setState(() {
      _working = true;
      _report = isDryRun ? '预演中…' : '导入中…';
    });
    try {
      final temp = await getTemporaryDirectory();
      final options = AstrBotImportOptions(
        isDryRun: isDryRun,
        replacesPreviousImports: !isDryRun,
        stagingDirectory: '${temp.path}/astrbot-staging',
      );
      final report = await container.astrbot.run(sources, options);
      setState(() => _report = _summarize(report));
    } catch (error) {
      setState(() => _report = '${isDryRun ? '预演' : '导入'}失败：$error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// 报告摘要（关键计数 + 覆盖校验）
  String _summarize(AstrBotImportReport report) {
    final c = report.counts;
    final buffer = StringBuffer()
      ..writeln(report.isDryRun ? '预演完成（数据未落库）' : '导入完成')
      ..writeln('状态：${report.status.value}')
      ..writeln('消息：新增 ${c.messagesNew} · 重复 ${c.messagesDuplicate} · 待处理 ${c.messagesPending}')
      ..writeln('记忆：新增 ${c.memoriesNew + c.companionMemoriesNew} · 重复 ${c.memoriesDuplicate + c.companionMemoriesDuplicate}')
      ..writeln('日记：新增 ${c.diariesNew} · 待处理 ${c.diaryPending}')
      ..writeln('文档（信件/笔记）：新增 ${c.documentsNew}')
      ..writeln('人格条目：新增 ${c.personaItemsNew}')
      ..writeln('待处理合计：${c.pendingTotal}');
    final problems = c.coverageProblems;
    if (problems.isEmpty) {
      buffer.write('覆盖校验：通过（每个源行都有归属）');
    } else {
      buffer.write('覆盖校验异常：${problems.join('；')}');
    }
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasSource = _probed.values.any((bool exists) => exists);
    return Scaffold(
      appBar: AppBar(title: const Text('AstrBot 数据导入'), centerTitle: false),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text(
            '选择 AstrBot 的数据根目录（包含 data/、diary/、letters/ 等子目录的那一层）。'
            '导入过程不会修改源文件。',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: _working ? null : _pickRoot,
            icon: const Icon(Icons.folder_open),
            label: Text(_rootPath == null ? '选择数据根目录' : '重新选择'),
          ),
          if (_rootPath != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(_rootPath!, style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: theme.colorScheme.outlineVariant.withAlpha(80)),
              ),
              child: Column(
                children: <Widget>[
                  for (final (String label, String rel) in _probeLayout)
                    ListTile(
                      dense: true,
                      leading: Icon(
                        (_probed[label] ?? false) ? Icons.check_circle : Icons.remove_circle_outline,
                        color: (_probed[label] ?? false)
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outline,
                        size: 20,
                      ),
                      title: Text(label),
                      subtitle: Text(rel, style: theme.textTheme.bodySmall),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _working || !hasSource ? null : _dryRun,
                    icon: const Icon(Icons.preview_outlined),
                    label: const Text('预演'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _working || !hasSource ? null : _confirmRealRun,
                    icon: const Icon(Icons.download_done),
                    label: const Text('正式导入'),
                  ),
                ),
              ],
            ),
          ],
          if (_working) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
          if (_report != null) ...<Widget>[
            const SizedBox(height: 16),
            Card(
              elevation: 0,
              color: theme.colorScheme.surfaceContainerHighest.withAlpha(60),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(_report!, style: theme.textTheme.bodySmall),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

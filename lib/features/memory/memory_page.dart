/// 记忆库管理页：FTS 全文搜索 + 列表浏览 + 软删除。
///
/// 检索口径与召回一致（MemoryRepository.search：bigram AND 优先、OR 兜底）。
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../app_container.dart';
import '../../domain/models/memory.dart';

final DateFormat _fmt = DateFormat('MM-dd HH:mm');

/// 记忆层级与范围的中文徽标
const Map<String, String> _scopeLabels = <String, String>{
  'shared': '共同',
  'private': '她的',
  'user': '我的',
  'world': '世界',
};
const Map<String, String> _layerLabels = <String, String>{
  'semantic': '事实',
  'episodic': '事件',
  'procedural': '习惯',
  'emotional': '情绪',
};

class MemoryPage extends StatefulWidget {
  const MemoryPage({super.key});

  @override
  State<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends State<MemoryPage> {
  final TextEditingController _query = TextEditingController();
  List<MemoryRecord> _records = <MemoryRecord>[];
  bool _searching = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final container = context.read<AppContainer>();
    final query = _query.text.trim();
    try {
      final records = query.isEmpty
          ? await container.memories.list(limit: 200)
          : await container.memories.search(query: query, limit: 50);
      if (!mounted) return;
      setState(() {
        _records = records;
        _searching = query.isNotEmpty;
        _message = null;
      });
    } catch (error) {
      if (mounted) setState(() => _message = '读取失败：$error');
    }
  }

  Future<void> _confirmDelete(MemoryRecord record) async {
    final container = context.read<AppContainer>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('删除这条记忆？'),
        content: Text('「${record.title}」删除后不再被召回，但保留在数据库里以便追溯。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await container.memories.softDelete(
      record.id,
      at: DateTime.now().millisecondsSinceEpoch,
    );
    _toast('已删除：${record.title}');
    await _reload();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('记忆库管理'), centerTitle: false),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _query,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _reload(),
              decoration: InputDecoration(
                hintText: '搜索大肥鱼记住的事情…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searching
                    ? IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _query.clear();
                          _reload();
                        },
                      )
                    : IconButton(
                        icon: const Icon(Icons.arrow_forward),
                        tooltip: '搜索',
                        onPressed: _reload,
                      ),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _searching
                    ? '找到 ${_records.length} 条相关记忆'
                    : '共 ${_records.length} 条（按重要程度排序）',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
          ),
          const Divider(height: 16),
          Expanded(
            child: _message != null
                ? Center(child: Text(_message!))
                : _records.isEmpty
                    ? Center(
                        child: Text(
                          _searching ? '没有匹配的记忆' : '记忆库还是空的\n多聊几天就会记住彼此了',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: theme.colorScheme.outline),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 16),
                        itemCount: _records.length,
                        itemBuilder: (BuildContext context, int index) =>
                            _tile(context, _records[index]),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, MemoryRecord record) {
    return ListTile(
      title: Text(
        record.title.isEmpty ? '（无题）' : record.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(record.content, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 6),
            _badges(context, record),
          ],
        ),
      ),
      isThreeLine: true,
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline, size: 20),
        tooltip: '删除',
        onPressed: () => _confirmDelete(record),
      ),
    );
  }

  // 徽标辅助（与条目布局一起用）
  Widget _badges(BuildContext context, MemoryRecord record) {
    final theme = Theme.of(context);
    final shownAt = record.lastRecalledAt ?? record.updatedAt;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: <Widget>[
        _badge(theme, _scopeLabels[record.scope] ?? record.scope, theme.colorScheme.primary),
        _badge(theme, _layerLabels[record.layer] ?? record.layer, theme.colorScheme.tertiary),
        _badge(theme, '召回 ${record.recallCount}', theme.colorScheme.outline),
        if (shownAt > 0) _badge(theme, _fmt.format(DateTime.fromMillisecondsSinceEpoch(shownAt)),
            theme.colorScheme.outline),
      ],
    );
  }

  Widget _badge(ThemeData theme, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(24),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text, style: theme.textTheme.labelSmall?.copyWith(color: color)),
    );
  }
}

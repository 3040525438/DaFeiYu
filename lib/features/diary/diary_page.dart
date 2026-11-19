/// 日记页：日记列表 / 详情编辑 / 一键生成今日日记 + 信件视图（同页切换）。
///
/// 生成硬约束由 [DiaryAutoService] 保证：消息不足跳过、用户手写不覆盖、
/// 解析失败不写库；本页只负责把结果如实呈现。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/diary_auto_service.dart';
import '../../ai/openai_compatible_provider.dart';
import '../../app_container.dart';
import '../../core/time/local_day.dart';
import '../../domain/models/diary.dart';
import '../../domain/models/memory.dart';

/// 日记状态对应的心情 emoji（界面展示用，六码白名单外不显示）
const Map<String, String> _moodEmoji = <String, String>{
  'calm': '😌', 'warm': '🫶', 'happy': '😊', 'tired': '😴', 'low': '🌧️', 'excited': '🤩',
};

class DiaryPage extends StatefulWidget {
  const DiaryPage({super.key});

  @override
  State<DiaryPage> createState() => _DiaryPageState();
}

class _DiaryPageState extends State<DiaryPage> {
  bool _lettersView = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_lettersView ? '信件' : '日记'),
        centerTitle: false,
        actions: <Widget>[
          SegmentedButton<bool>(
            segments: const <ButtonSegment<bool>>[
              ButtonSegment<bool>(value: false, icon: Icon(Icons.menu_book_outlined), label: Text('日记')),
              ButtonSegment<bool>(value: true, icon: Icon(Icons.mail_outline), label: Text('信件')),
            ],
            selected: <bool>{_lettersView},
            onSelectionChanged: (Set<bool> selection) =>
                setState(() => _lettersView = selection.first),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: _lettersView ? const _LettersView() : const _DiaryView(),
    );
  }
}

// ── 日记视图 ────────────────────────────────────────────────────────────────

class _DiaryView extends StatefulWidget {
  const _DiaryView();

  @override
  State<_DiaryView> createState() => _DiaryViewState();
}

class _DiaryViewState extends State<_DiaryView> {
  List<DiaryEntry> _entries = <DiaryEntry>[];
  bool _generating = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final container = context.read<AppContainer>();
    final entries = await container.diaries.recent(limit: 100);
    if (mounted) setState(() => _entries = entries);
  }

  /// 一键生成今日日记（失败/跳过都以提示条如实呈现，不用假数据填充）
  Future<void> _generateToday() async {
    final container = context.read<AppContainer>();
    setState(() {
      _generating = true;
      _message = null;
    });
    try {
      final config = await container.modelConfigs.defaultConfig();
      if (config == null) {
        setState(() => _message = '还没有模型配置，请先到「设置」页保存');
        return;
      }
      final apiKey = await container.readApiKey(config.keyRef);
      if (apiKey == null || apiKey.isEmpty) {
        setState(() => _message = '未找到 API 密钥，请到「设置」页重新保存');
        return;
      }
      final persona = await container.personas.coreSystemPrompt() ?? '';
      final provider = OpenAICompatibleProvider(
        baseUrl: config.baseUrl,
        modelId: config.modelId,
        apiKey: apiKey,
      );
      final dayKey = DiaryAutoService.dayKeyFromMillis(DateTime.now().millisecondsSinceEpoch);
      final report = await container.diaryAuto.generate(dayKey, provider: provider, persona: persona);
      setState(() {
        _message = '${report.dayKey} · ${report.status.value} · ${report.note}';
      });
      await _reload();
    } catch (error) {
      setState(() => _message = '生成失败：$error');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _openEditor([DiaryEntry? entry]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) => _DiaryEditorSheet(entry: entry),
    );
    if (saved == true && mounted) await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _message ?? '今天的日记写了吗？',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                ),
              ),
              FilledButton.icon(
                onPressed: _generating ? null : _generateToday,
                icon: _generating
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.auto_awesome),
                label: const Text('生成今日'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => _openEditor(),
                icon: const Icon(Icons.edit_note),
                label: const Text('手写'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _entries.isEmpty
              ? const Center(child: Text('还没有日记\n聊完一天再来生成一篇吧', textAlign: TextAlign.center))
              : ListView.builder(
                  itemCount: _entries.length,
                  itemBuilder: (BuildContext context, int index) {
                    final entry = _entries[index];
                    final pendingConfirm =
                        entry.relationshipChange.trim().isNotEmpty && !entry.relationshipChangeConfirmed;
                    return ListTile(
                      leading: Text(
                        _moodEmoji[entry.moodCode] ?? '📝',
                        style: const TextStyle(fontSize: 22),
                      ),
                      title: Text(
                        entry.title.isEmpty ? entry.entryDate : entry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        entry.content,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          if (pendingConfirm)
                            GestureDetector(
                              onTap: () => _confirmRelationshipChange(entry),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.tertiary.withAlpha(28),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  '待确认',
                                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                        color: Theme.of(context).colorScheme.tertiary,
                                      ),
                                ),
                              ),
                            ),
                          const SizedBox(width: 6),
                          Text(
                            entry.entryDate.substring(5),
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ],
                      ),
                      onTap: () => _openEditor(entry),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// 一键确认这条日记记录的关系变化（写版本快照留痕）
  Future<void> _confirmRelationshipChange(DiaryEntry entry) async {
    final container = context.read<AppContainer>();
    try {
      await container.diaries.confirmRelationshipChange(
        entry.id,
        atMillis: DateTime.now().millisecondsSinceEpoch,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('已确认这次关系变化')));
      await _reload();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('确认失败：$error')));
    }
  }
}

/// 日记编辑抽屉：新增（手写）或编辑既有条目；保存留版本快照。
class _DiaryEditorSheet extends StatefulWidget {
  const _DiaryEditorSheet({this.entry});

  final DiaryEntry? entry;

  @override
  State<_DiaryEditorSheet> createState() => _DiaryEditorSheetState();
}

class _DiaryEditorSheetState extends State<_DiaryEditorSheet> {
  late final TextEditingController _title;
  late final TextEditingController _content;
  String? _mood;
  late final String? _relationshipChange;
  bool _relationshipConfirmed = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.entry?.title ?? '');
    _content = TextEditingController(text: widget.entry?.content ?? '');
    _mood = widget.entry?.moodCode;
    _relationshipChange = widget.entry?.relationshipChange;
    _relationshipConfirmed = widget.entry?.relationshipChangeConfirmed ?? false;
  }

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final container = context.read<AppContainer>();
    final content = _content.text.trim();
    if (content.isEmpty) {
      setState(() => _error = '正文不能为空');
      return;
    }
    try {
      final date = widget.entry?.entryDate ??
          DiaryAutoService.dayKeyFromMillis(DateTime.now().millisecondsSinceEpoch);
      await container.diaries.upsert(
        DiaryUpsert(
          entryDate: date,
          title: _title.text.trim(),
          content: content,
          moodCode: _mood,
          source: 'manual',
          isUserEdited: true,
          sharedExperience: widget.entry?.sharedExperience ?? '',
          observation: widget.entry?.observation ?? '',
          feeling: widget.entry?.feeling ?? '',
          relationshipChange: widget.entry?.relationshipChange ?? '',
          relationshipChangeConfirmed: _relationshipConfirmed,
          changeReason: widget.entry == null ? '用户手写日记' : '用户编辑日记',
          changedBy: 'user',
        ),
        atMillis: DateTime.now().millisecondsSinceEpoch,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final moods = _moodEmoji.keys.toList();
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              widget.entry == null ? '手写日记' : '编辑日记（${widget.entry!.entryDate}）',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _title,
              decoration: const InputDecoration(labelText: '标题（可留空）'),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              children: moods.map((String mood) {
                return ChoiceChip(
                  label: Text(_moodEmoji[mood] ?? mood),
                  selected: _mood == mood,
                  onSelected: (bool selected) => setState(() => _mood = selected ? mood : null),
                );
              }).toList(),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _content,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: '正文',
                alignLabelWithHint: true,
              ),
            ),
            if (_relationshipChange != null && _relationshipChange.trim().isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.tertiary.withAlpha(24),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Icon(Icons.favorite_border,
                            size: 16, color: Theme.of(context).colorScheme.tertiary),
                        const SizedBox(width: 6),
                        Text(
                          '日记里观察到的关系变化',
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                color: Theme.of(context).colorScheme.tertiary,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SelectableText(_relationshipChange),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: _relationshipConfirmed,
                      onChanged: (bool value) =>
                          setState(() => _relationshipConfirmed = value),
                      title: const Text('确认这次关系变化'),
                      subtitle: const Text('确认后大肥鱼会把它当作真实的相处进展'),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            if (_error != null)
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _save,
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 信件视图 ────────────────────────────────────────────────────────────────

/// 信件 = memories 表 type='letter' 的文档记忆（与 AstrBot 导入口径一致）。
class _LettersView extends StatefulWidget {
  const _LettersView();

  @override
  State<_LettersView> createState() => _LettersViewState();
}

class _LettersViewState extends State<_LettersView> {
  List<MemoryRecord> _letters = <MemoryRecord>[];
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final container = context.read<AppContainer>();
    try {
      final letters = await container.memories.listByType('letter');
      if (mounted) setState(() => _letters = letters);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _openCompose() async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) => const _LetterComposeSheet(),
    );
    if (saved == true && mounted) await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _error ?? '信件与读书笔记都存在记忆库里，聊到相关话题会被召回',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                ),
              ),
              FilledButton.icon(
                onPressed: _openCompose,
                icon: const Icon(Icons.drive_file_rename_outline),
                label: const Text('写一封'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _letters.isEmpty
              ? const Center(child: Text('还没有信件\n第一封信从「写一封」开始'))
              : ListView.builder(
                  itemCount: _letters.length,
                  itemBuilder: (BuildContext context, int index) {
                    final letter = _letters[index];
                    return ListTile(
                      leading: const Icon(Icons.markunread_mailbox_outlined),
                      title: Text(letter.title.isEmpty ? '（无题）' : letter.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(letter.content, maxLines: 2, overflow: TextOverflow.ellipsis),
                      onTap: () {
                        showModalBottomSheet<void>(
                          context: context,
                          isScrollControlled: true,
                          builder: (BuildContext sheetContext) => Padding(
                            padding: EdgeInsets.fromLTRB(
                                24, 24, 24, MediaQuery.of(sheetContext).viewInsets.bottom + 24),
                            child: SingleChildScrollView(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(letter.title.isEmpty ? '（无题）' : letter.title,
                                      style: Theme.of(sheetContext).textTheme.titleLarge),
                                  const SizedBox(height: 12),
                                  SelectableText(letter.content),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// 写信抽屉：落库为 memories(type='letter', scope='shared')，FTS 自动建索引。
class _LetterComposeSheet extends StatefulWidget {
  const _LetterComposeSheet();

  @override
  State<_LetterComposeSheet> createState() => _LetterComposeSheetState();
}

class _LetterComposeSheetState extends State<_LetterComposeSheet> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _content = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final container = context.read<AppContainer>();
    final content = _content.text.trim();
    if (content.isEmpty) {
      setState(() => _error = '信的内容不能为空');
      return;
    }
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final day = dayKey(DateTime(now));
      await container.memories.insert(
        MemoryRecord(
          id: 'letter-$now',
          type: 'letter',
          title: _title.text.trim().isEmpty ? '一封信 · $day' : _title.text.trim(),
          content: content,
          category: 'letter',
          sourceKind: 'real_interaction',
          dedupeKey: 'letter:$now',
          firstSeenAt: now,
          createdAt: now,
          updatedAt: now,
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('写一封信', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: '标题（可留空）'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _content,
            maxLines: 10,
            decoration: const InputDecoration(
              labelText: '想对大肥鱼说的话',
              alignLabelWithHint: true,
            ),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _send,
            child: const Text('收进记忆库'),
          ),
        ],
      ),
    );
  }
}

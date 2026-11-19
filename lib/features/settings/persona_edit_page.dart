/// 人格编辑页：查看与编辑大肥鱼的核心系统提示词（persona_items system_prompt）。
///
/// 每次保存都会写 persona_versions 快照（changed_by='user'），可追溯。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_container.dart';

class PersonaEditPage extends StatefulWidget {
  const PersonaEditPage({super.key});

  @override
  State<PersonaEditPage> createState() => _PersonaEditPageState();
}

class _PersonaEditPageState extends State<PersonaEditPage> {
  final TextEditingController _prompt = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  String? _message;
  bool _hasPersona = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prompt = await context.read<AppContainer>().personas.coreSystemPrompt();
    if (!mounted) return;
    setState(() {
      _prompt.text = prompt ?? '';
      _hasPersona = prompt != null && prompt.isNotEmpty;
      _loading = false;
    });
  }

  Future<void> _save() async {
    final text = _prompt.text.trim();
    if (text.isEmpty) {
      setState(() => _message = '系统提示词不能为空');
      return;
    }
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      await context.read<AppContainer>().personas.saveCoreSystemPrompt(
            text,
            atMillis: DateTime.now().millisecondsSinceEpoch,
          );
      if (!mounted) return;
      setState(() {
        _message = '已保存（生成回复、日记都会使用这份提示词）';
        _hasPersona = true;
      });
    } catch (error) {
      if (mounted) setState(() => _message = '保存失败：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('人格设定'), centerTitle: false),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                Text(
                  '核心系统提示词',
                  style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary),
                ),
                const SizedBox(height: 4),
                Text(
                  _hasPersona
                      ? '这是大肥鱼「是谁」的定义：语气、称呼、相处方式都在这里。'
                      : '还没有核心人格——写下第一段，或先到「AstrBot 数据导入」迁移现有人格。',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _prompt,
                  maxLines: 16,
                  minLines: 8,
                  decoration: const InputDecoration(
                    hintText: '例如：你是大肥鱼，一只会聊天也会记录生活的陪伴者……',
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.save_outlined),
                  label: const Text('保存'),
                ),
                if (_message != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(_message!, style: theme.textTheme.bodySmall),
                ],
              ],
            ),
    );
  }
}

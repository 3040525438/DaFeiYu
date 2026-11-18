/// 模型配置页：真实读写 model_configs 表与安全存储。
library;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:provider/provider.dart';

import '../../app_container.dart';
import '../../domain/models/model_config.dart';

class ModelConfigPage extends StatefulWidget {
  const ModelConfigPage({super.key});

  @override
  State<ModelConfigPage> createState() => _ModelConfigPageState();
}

class _ModelConfigPageState extends State<ModelConfigPage> {
  final _name = TextEditingController();
  final _baseUrl = TextEditingController();
  final _modelId = TextEditingController();
  final _apiKey = TextEditingController();
  List<ModelConfig> _configs = <ModelConfig>[];
  String? _message;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final container = context.read<AppContainer>();
    final configs = await container.modelConfigs.list();
    if (!mounted) return;
    setState(() => _configs = configs);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final baseUrl = _baseUrl.text.trim();
    final modelId = _modelId.text.trim();
    final apiKey = _apiKey.text.trim();
    if (name.isEmpty || baseUrl.isEmpty || modelId.isEmpty || apiKey.isEmpty) {
      setState(() => _message = '名称、Base URL、模型 ID、API 密钥都要填写');
      return;
    }
    final container = context.read<AppContainer>();
    final now = DateTime.now().millisecondsSinceEpoch;
    final keyRef = 'model-key-${const Uuid().v4()}';
    await container.saveApiKey(keyRef, apiKey);
    await container.modelConfigs.upsert(
      ModelConfig(
        id: const Uuid().v4(),
        name: name,
        baseUrl: baseUrl,
        modelId: modelId,
        keyRef: keyRef,
        isDefault: true,
        createdAt: now,
        updatedAt: now,
      ),
    );
    _name.clear();
    _baseUrl.clear();
    _modelId.clear();
    _apiKey.clear();
    setState(() => _message = '已保存，并设为默认');
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('模型配置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: '配置名称（如：豆包 / DeepSeek）'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _baseUrl,
            decoration: const InputDecoration(
              labelText: 'Base URL（如：https://ark.cn-beijing.volces.com/api/v3）',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _modelId,
            decoration: const InputDecoration(labelText: '模型 ID（如：doubao-pro-32k）'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _apiKey,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'API 密钥（仅存本机安全存储）'),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: const Text('保存为新配置并设为默认'),
          ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_message!, style: const TextStyle(fontSize: 12)),
            ),
          const Divider(height: 32),
          Text('已有配置（${_configs.length}）',
              style: Theme.of(context).textTheme.titleSmall),
          for (final config in _configs)
            ListTile(
              title: Text(config.name),
              subtitle: Text('${config.modelId}\n${config.baseUrl}'),
              isThreeLine: true,
              trailing: config.isDefault
                  ? const Chip(label: Text('默认'))
                  : IconButton(
                      icon: const Icon(Icons.star_border),
                      tooltip: '设为默认',
                      onPressed: () async {
                        final container = context.read<AppContainer>();
                        await container.modelConfigs.upsert(
                          ModelConfig(
                            id: config.id,
                            name: config.name,
                            baseUrl: config.baseUrl,
                            modelId: config.modelId,
                            keyRef: config.keyRef,
                            isDefault: true,
                            createdAt: config.createdAt,
                            updatedAt: DateTime.now().millisecondsSinceEpoch,
                          ),
                        );
                        _reload();
                      },
                    ),
            ),
        ],
      ),
    );
  }
}

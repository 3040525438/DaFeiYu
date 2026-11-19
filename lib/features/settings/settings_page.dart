/// 设置主页：模型配置 / 人格 / 记忆库 / 备份与恢复 / AstrBot 导入 的统一入口。
library;

import 'package:flutter/material.dart';

import 'astrbot_import_page.dart';
import 'backup_page.dart';
import '../memory/memory_page.dart';
import 'model_config_page.dart';
import 'persona_edit_page.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        centerTitle: false,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text('对话与人格', style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
          const SizedBox(height: 8),
          _EntryCard(
            icon: Icons.tune,
            title: '模型配置',
            subtitle: 'Base URL、模型 ID 与 API 密钥（仅存本机）',
            onTap: () => _push(context, const ModelConfigPage()),
          ),
          _EntryCard(
            icon: Icons.face_retouching_natural,
            title: '人格设定',
            subtitle: '编辑大肥鱼的核心系统提示词',
            onTap: () => _push(context, const PersonaEditPage()),
          ),
          const SizedBox(height: 20),
          Text('记忆与数据', style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
          const SizedBox(height: 8),
          _EntryCard(
            icon: Icons.psychology_outlined,
            title: '记忆库管理',
            subtitle: '查看、搜索与删除大肥鱼记住的事情',
            onTap: () => _push(context, const MemoryPage()),
          ),
          _EntryCard(
            icon: Icons.backup_outlined,
            title: '备份与恢复',
            subtitle: '加密备份、从文件恢复（.dfbk / .json）',
            onTap: () => _push(context, const BackupPage()),
          ),
          _EntryCard(
            icon: Icons.import_contacts_outlined,
            title: 'AstrBot 数据导入',
            subtitle: '从 AstrBot 数据目录覆盖式导入聊天与记忆',
            onTap: () => _push(context, const AstrBotImportPage()),
          ),
          const SizedBox(height: 20),
          Center(
            child: Text(
              '所有数据都保存在本机，API 密钥只存系统安全存储',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
        ],
      ),
    );
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (BuildContext context) => page),
    );
  }
}

/// 单个设置入口卡片
class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: theme.colorScheme.outlineVariant.withAlpha(80)),
        ),
        child: ListTile(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          leading: Icon(icon, color: theme.colorScheme.primary),
          title: Text(title, style: theme.textTheme.titleMedium),
          subtitle: Text(subtitle, style: theme.textTheme.bodySmall),
          trailing: Icon(Icons.chevron_right, color: theme.colorScheme.outline),
          onTap: onTap,
        ),
      ),
    );
  }
}

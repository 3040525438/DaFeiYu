/// 备份与恢复页：创建加密备份、从文件导入、验证、恢复（覆盖式）与分享导出。
///
/// 恢复的硬约束在 [BackupService] 里：版本兼容检查、恢复前自动留安全备份、
/// 事务整体回滚；本页只负责把风险讲清楚并收集用户确认。
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app_container.dart';
import '../../domain/models/backup.dart';

final DateFormat _fmt = DateFormat('yyyy-MM-dd HH:mm');

class BackupPage extends StatefulWidget {
  const BackupPage({super.key});

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  List<BackupManifest> _manifests = <BackupManifest>[];
  bool _working = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final manifests = await context.read<AppContainer>().backup.manifestsList();
    if (!mounted) return;
    setState(() => _manifests = manifests);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 创建加密备份（DFBK1 容器，密钥只存本机安全存储）
  Future<void> _createBackup() async {
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      final manifest = await context.read<AppContainer>().backup.createBackup(
            kind: BackupKind.manual,
            note: '手动备份（设置页）',
          );
      _toast('备份完成：${manifest.fileName}（${_fmtSize(manifest.byteSize)}）');
      await _reload();
    } catch (error) {
      _toast('备份失败：$error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// 从文件导入备份（只登记，不自动恢复）
  Future<void> _importFile() async {
    final container = context.read<AppContainer>();
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      dialogTitle: '选择大肥鱼备份文件（.dfbk / .json）',
    );
    final path = result?.files.single.path;
    if (path == null) return;
    setState(() => _working = true);
    try {
      final manifest = await container.backup.importBackupFile(path);
      _toast('已导入备份：${manifest.fileName}，可在列表中选择「恢复」');
      await _reload();
    } catch (error) {
      _toast('导入失败：$error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _verify(BackupManifest manifest) async {
    final container = context.read<AppContainer>();
    setState(() => _working = true);
    try {
      final verification = await container.backup.verify(manifest.id);
      _toast(verification.sha256Matches && verification.decrypted
          ? '验证通过：校验和一致且可解密'
          : '验证未通过（校验和 ${verification.sha256Matches ? '一致' : '不一致'}）');
    } catch (error) {
      _toast('验证失败：$error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// 恢复前确认：覆盖式 + 自动安全备份都要说清楚
  Future<void> _confirmRestore(BackupManifest manifest) async {
    final container = context.read<AppContainer>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('恢复这份备份？'),
        content: Text(
          '「${manifest.fileName}」将覆盖本机的全部数据。\n\n'
          '恢复前会自动生成一份安全备份；若恢复结果不满意，可以再用安全备份退回。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确认恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _working = true);
    try {
      final log = await container.backup.restore(
        manifest.id,
        confirmedCrossDevice: true,
      );
      if (log.status == 'completed') {
        _toast('恢复完成，已自动生成安全备份');
      } else {
        _toast('恢复失败：${log.error ?? '未知错误'}（原数据未受影响）');
      }
    } catch (error) {
      _toast('恢复失败：$error（原数据未受影响）');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _share(BackupManifest manifest) async {
    try {
      final file = context.read<AppContainer>().backup.fileURL(manifest);
      if (!file.existsSync()) {
        _toast('备份文件不存在：${manifest.fileName}');
        return;
      }
      await Share.shareXFiles(<XFile>[XFile(file.path)], text: '大肥鱼备份');
    } catch (error) {
      _toast('分享失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('备份与恢复'), centerTitle: false),
      body: Stack(
        children: <Widget>[
          ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              if (_message != null) Text(_message!),
              FilledButton.icon(
                onPressed: _working ? null : _createBackup,
                icon: _working
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.backup_outlined),
                label: const Text('创建加密备份'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _working ? null : _importFile,
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('从文件导入备份（.dfbk / .json）'),
              ),
              const SizedBox(height: 20),
              Text('备份记录（${_manifests.length}）',
                  style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
              const SizedBox(height: 8),
              if (_manifests.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 48),
                  child: Center(
                    child: Text(
                      '还没有备份\n重要对话聊完记得先备份一份',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ),
                )
              else
                for (final BackupManifest manifest in _manifests)
                  _manifestTile(context, manifest),
            ],
          ),
          if (_working)
            const Positioned.fill(
              child: IgnorePointer(child: Center(child: LinearProgressIndicator())),
            ),
        ],
      ),
    );
  }

  Widget _manifestTile(BuildContext context, BackupManifest manifest) {
    final theme = Theme.of(context);
    final usable = manifest.isUsable;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant.withAlpha(80)),
      ),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        leading: Icon(
          manifest.isEncrypted ? Icons.lock_outline : Icons.lock_open,
          color: manifest.isEncrypted ? theme.colorScheme.primary : theme.colorScheme.error,
        ),
        title: Text(manifest.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${_fmt.format(DateTime.fromMillisecondsSinceEpoch(manifest.createdAt))} · '
          '${_fmtSize(manifest.byteSize)} · '
          '${kindLabel(manifest.kind)} · ${manifest.status.name}',
        ),
        enabled: usable,
        trailing: PopupMenuButton<String>(
          itemBuilder: (BuildContext menuContext) => <PopupMenuEntry<String>>[
            const PopupMenuItem<String>(value: 'restore', child: Text('恢复（覆盖本机数据）')),
            const PopupMenuItem<String>(value: 'verify', child: Text('验证完整性')),
            const PopupMenuItem<String>(value: 'share', child: Text('分享 / 导出文件')),
          ],
          onSelected: (String action) {
            if (action == 'restore') _confirmRestore(manifest);
            if (action == 'verify') _verify(manifest);
            if (action == 'share') _share(manifest);
          },
        ),
      ),
    );
  }
}

/// 备份类型的中文标签
String kindLabel(BackupKind kind) => switch (kind) {
      BackupKind.manual => '手动',
      BackupKind.automatic => '自动',
      BackupKind.incremental => '增量',
      BackupKind.external => '外部',
      BackupKind.safety => '安全备份',
    };

/// 字节数的人类可读格式
String _fmtSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
}

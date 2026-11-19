/// 聊天页（对齐旧版交互：右对齐用户气泡、左对齐回复、发送中可取消）。
/// P1：图片理解入口（选图发送）与语音输入（录音→转写→文本）。
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../../app_container.dart';
import '../../ai/openai_compatible_provider.dart';
import '../../domain/models/conversation.dart';
import '../../domain/models/message.dart';
import 'chat_orchestrator.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final Map<String, String> _streaming = <String, String>{};
  final AudioRecorder _recorder = AudioRecorder();
  List<Message> _history = <Message>[];
  String _conversationId = '';
  bool _sending = false;
  bool _recording = false;
  String? _pendingImagePath;
  StreamSubscription<ChatEvent>? _subscription;
  String? _lastError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _input.dispose();
    _scroll.dispose();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final container = context.read<AppContainer>();
    final conversationId = await container.chat.ensureMainConversation();
    final history = await container.messages.list(conversationId);
    if (!mounted) return;
    setState(() {
      _conversationId = conversationId;
      _history = history;
    });
    _prefetchImagePaths(history);
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    final imagePath = _pendingImagePath;
    if ((text.isEmpty && imagePath == null) || _sending) return;
    _input.clear();
    setState(() {
      _sending = true;
      _lastError = null;
      _pendingImagePath = null;
    });
    final container = context.read<AppContainer>();
    _subscription = container.chat.send(_conversationId, text, imagePath: imagePath).listen(
      (ChatEvent event) {
        if (event is ChatDeltaEvent) {
          setState(() => _streaming[event.messageId] = event.accumulated);
          _scrollToBottom();
        } else if (event is ChatFinishedEvent) {
          setState(() => _streaming.remove(event.messageId));
          _reload();
        } else if (event is ChatFailedEvent) {
          setState(() {
            _streaming.remove(event.messageId);
            _lastError = event.error;
          });
        }
      },
      onDone: () {
        if (!mounted) return;
        setState(() => _sending = false);
        _reload();
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _sending = false;
          _lastError = error.toString();
        });
      },
    );
  }

  Future<void> _cancel() async {
    final container = context.read<AppContainer>();
    await container.chat.cancel();
    _subscription?.cancel();
    if (mounted) {
      setState(() => _sending = false);
    }
    _reload();
  }

  /// 选图：作为待发图片，正文可为空（说明文字可选）
  Future<void> _pickImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: false,
    );
    final path = result?.files.single.path;
    if (path != null && mounted) {
      setState(() => _pendingImagePath = path);
    }
  }

  /// 语音输入：开始/停止录音 → /audio/transcriptions 转写 → 填入输入框。
  /// 转写失败如实提示（部分网关不提供该端点），不假装成功。
  Future<void> _toggleRecording() async {
    if (_recording) {
      final path = await _recorder.stop();
      setState(() => _recording = false);
      if (path == null) {
        setState(() => _lastError = '录音未成功保存');
        return;
      }
      setState(() {
        _lastError = null;
      });
      if (!mounted) return;
      try {
        final container = context.read<AppContainer>();
        final config = await container.modelConfigs.defaultConfig();
        final apiKey = config == null ? null : await container.readApiKey(config.keyRef);
        if (config == null || apiKey == null || apiKey.isEmpty) {
          setState(() => _lastError = '尚未配置模型，无法转写语音');
          return;
        }
        final provider = OpenAICompatibleProvider(
          baseUrl: config.baseUrl,
          modelId: config.modelId,
          apiKey: apiKey,
        );
        final bytes = await _readBytes(path);
        final text = await provider.transcribe(
          bytes,
          fileName: path.replaceAll('\\', '/').split('/').last,
          mimeType: path.toLowerCase().endsWith('.wav') ? 'audio/wav' : 'audio/m4a',
        );
        final trimmed = text.trim();
        if (trimmed.isEmpty) {
          setState(() => _lastError = '转写结果为空');
        } else {
          _input.text = trimmed;
        }
      } catch (error) {
        setState(() => _lastError = '语音转写失败（当前服务可能不支持 /audio/transcriptions）：$error');
      }
      return;
    }
    try {
      if (await _recorder.hasPermission()) {
        final dir = await _tempRecordingPath();
        await _recorder.start(
          const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 128000, sampleRate: 44100),
          path: dir,
        );
        setState(() {
          _recording = true;
          _lastError = null;
        });
      } else {
        setState(() => _lastError = '没有麦克风权限，无法录音');
      }
    } catch (error) {
      setState(() => _lastError = '录音启动失败：$error');
    }
  }

  Future<String> _tempRecordingPath() async {
    final temp = await getTemporaryDirectory();
    return '${temp.path}/voice-${DateTime.now().millisecondsSinceEpoch}.m4a';
  }

  Future<List<int>> _readBytes(String path) => File(path).readAsBytes();

  Future<void> _reload() async {
    final container = context.read<AppContainer>();
    final history = await container.messages.list(_conversationId);
    if (!mounted) return;
    setState(() => _history = history);
    _prefetchImagePaths(history);
    _scrollToBottom();
  }

  /// 一次性预取图片消息的附件路径，避免 build 中触发 setState 循环。
  void _prefetchImagePaths(List<Message> history) {
    final missing = history
        .where((Message m) => m.kind == MessageKind.image && !_imagePaths.containsKey(m.id))
        .map((Message m) => m.id)
        .toList();
    if (missing.isEmpty) return;
    () async {
      final container = context.read<AppContainer>();
      for (final String id in missing) {
        _imagePaths[id] = await container.messages.imagePathsForMessage(id);
      }
      if (mounted) setState(() {});
    }();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// 切换会话：换 id 并重载历史（进行中的生成直接丢弃流）
  Future<void> _switchConversation(String id) async {
    if (id == _conversationId) return;
    final container = context.read<AppContainer>();
    _subscription?.cancel();
    await container.chat.cancel();
    final history = await container.messages.list(id);
    if (!mounted) return;
    setState(() {
      _conversationId = id;
      _history = history;
      _streaming.clear();
      _sending = false;
      _lastError = null;
    });
    _prefetchImagePaths(history);
    _scrollToBottom();
  }

  /// 新建会话并切换过去
  Future<void> _newConversation() async {
    final container = context.read<AppContainer>();
    final now = DateTime.now().millisecondsSinceEpoch;
    final conversation = Conversation(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: '新对话',
      kind: 'chat',
      createdAt: now,
      updatedAt: now,
    );
    await container.conversations.upsert(conversation);
    await _switchConversation(conversation.id);
  }

  /// 删除会话（消息随外键级联删除）；删的是当前会话时退回主会话
  Future<void> _deleteConversation(Conversation conversation) async {
    final container = context.read<AppContainer>();
    final wasCurrent = conversation.id == _conversationId;
    await container.conversations.delete(conversation.id);
    if (wasCurrent) {
      final mainId = await container.chat.ensureMainConversation();
      await _switchConversation(mainId);
    }
    _toast('已删除会话「${conversation.title}」');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 会话列表抽屉：切换 / 新建 / 删除
  Future<void> _openConversations() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) => _ConversationSheet(
        currentId: _conversationId,
        onSelect: (String id) {
          Navigator.of(sheetContext).pop();
          _switchConversation(id);
        },
        onCreate: () {
          Navigator.of(sheetContext).pop();
          _newConversation();
        },
        onDelete: (Conversation conversation) async {
          await _deleteConversation(conversation);
          if (sheetContext.mounted) Navigator.of(sheetContext).pop();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = <Widget>[
      for (final message in _history) _bubble(message),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('大肥鱼'),
        actions: <Widget>[
          IconButton(
            onPressed: _openConversations,
            icon: const Icon(Icons.forum_outlined),
            tooltip: '会话列表',
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (_lastError != null)
            Container(
              width: double.infinity,
              color: Colors.red.shade50,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                '出错了：$_lastError',
                style: TextStyle(color: Colors.red.shade700, fontSize: 12),
              ),
            ),
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: entries,
            ),
          ),
          SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (_pendingImagePath != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: Row(
                      children: <Widget>[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(
                            File(_pendingImagePath!),
                            width: 56,
                            height: 56,
                            fit: BoxFit.cover,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Expanded(child: Text('将随下一条消息发送')),
                        IconButton(
                          onPressed: () => setState(() => _pendingImagePath = null),
                          icon: const Icon(Icons.close),
                          tooltip: '移除图片',
                        ),
                      ],
                    ),
                  ),
                Row(
                  children: <Widget>[
                    IconButton(
                      onPressed: _pickImage,
                      icon: const Icon(Icons.image_outlined),
                      tooltip: '发图片',
                    ),
                    IconButton(
                      onPressed: _toggleRecording,
                      icon: Icon(_recording ? Icons.stop_circle : Icons.mic_none),
                      tooltip: _recording ? '停止录音并转写' : '语音输入',
                      color: _recording ? Colors.red : null,
                    ),
                    Expanded(
                      child: TextField(
                        controller: _input,
                        maxLines: null,
                        decoration: InputDecoration(
                          hintText: _recording ? '录音中…说完点一下麦克风' : '说点什么…',
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (_sending)
                      IconButton.outlined(
                        onPressed: _cancel,
                        icon: const Icon(Icons.stop),
                        tooltip: '停止生成',
                      )
                    else
                      IconButton.filled(
                        onPressed: _send,
                        icon: const Icon(Icons.send),
                        tooltip: '发送',
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(Message message) {
    final isUser = message.role == MessageRole.user;
    final text = _streaming[message.id] ?? message.text;
    final isStreaming = _streaming.containsKey(message.id);
    if (text.isEmpty && isStreaming) {
      return Align(
        alignment: Alignment.centerLeft,
        child: _card(
          child: const SizedBox(
            width: 40,
            height: 18,
            child: LinearProgressDivider(),
          ),
        ),
      );
    }
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: _card(
        color: isUser ? const Color(0xFFDCF8C6) : Colors.white,
        child: _bubbleContent(message, text),
      ),
    );
  }

  /// 气泡内容：图片消息渲染附件图 + 可选说明文字
  Widget _bubbleContent(Message message, String text) {
    final children = <Widget>[];
    if (message.kind == MessageKind.image) {
      final paths = _imagePaths[message.id] ?? const <String>[];
      if (paths.isEmpty) {
        children.add(const Text('（图片）', style: TextStyle(fontSize: 12)));
      }
      for (final String path in paths) {
        children.add(
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.file(
              File(path),
              width: 220,
              fit: BoxFit.cover,
              errorBuilder: (BuildContext context, Object _, StackTrace? __) =>
                  const Text('（图片文件已缺失）', style: TextStyle(fontSize: 12)),
            ),
          ),
        );
      }
    }
    if (text.isNotEmpty) {
      if (children.isNotEmpty) children.add(const SizedBox(height: 6));
      children.add(Text(text));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  final Map<String, List<String>> _imagePaths = <String, List<String>>{};

  Widget _card({required Widget child, Color? color}) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      constraints: const BoxConstraints(maxWidth: 300),
      decoration: BoxDecoration(
        color: color ?? Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const <BoxShadow>[
          BoxShadow(color: Color(0x11000000), blurRadius: 2),
        ],
      ),
      child: child,
    );
  }
}

class LinearProgressDivider extends StatelessWidget {
  const LinearProgressDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return const LinearProgressIndicator(minHeight: 2);
  }
}

/// 会话列表抽屉：按更新时间倒序列出全部会话，支持切换 / 新建 / 删除。
class _ConversationSheet extends StatefulWidget {
  const _ConversationSheet({
    required this.currentId,
    required this.onSelect,
    required this.onCreate,
    required this.onDelete,
  });

  final String currentId;
  final ValueChanged<String> onSelect;
  final VoidCallback onCreate;
  final Future<void> Function(Conversation conversation) onDelete;

  @override
  State<_ConversationSheet> createState() => _ConversationSheetState();
}

class _ConversationSheetState extends State<_ConversationSheet> {
  List<Conversation>? _conversations;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final list = await context.read<AppContainer>().conversations.list();
    if (!mounted) return;
    setState(() => _conversations = list);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final conversations = _conversations;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: <Widget>[
                Text('会话', style: theme.textTheme.titleMedium),
                const Spacer(),
                TextButton.icon(
                  onPressed: widget.onCreate,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('新对话'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (conversations == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            )
          else if (conversations.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('还没有会话'),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: conversations.length,
                itemBuilder: (BuildContext context, int index) {
                  final conversation = conversations[index];
                  final isCurrent = conversation.id == widget.currentId;
                  return ListTile(
                    leading: Icon(
                      isCurrent ? Icons.chat_bubble : Icons.chat_bubble_outline,
                      color: isCurrent ? theme.colorScheme.primary : null,
                    ),
                    title: Text(
                      conversation.title.isEmpty ? '（未命名）' : conversation.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: isCurrent
                          ? TextStyle(
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.primary,
                            )
                          : null,
                    ),
                    subtitle: Text(
                      _relativeTime(conversation.updatedAt),
                      style: theme.textTheme.bodySmall,
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 20),
                      tooltip: '删除会话',
                      onPressed: () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (BuildContext dialogContext) => AlertDialog(
                            title: const Text('删除这个会话？'),
                            content: Text(
                              '「${conversation.title}」里的全部消息都会被删除，删除后无法找回。',
                            ),
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
                        if (confirmed == true) await widget.onDelete(conversation);
                      },
                    ),
                    onTap: () => widget.onSelect(conversation.id),
                  );
                },
              ),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// 更新时间的相对描述
  String _relativeTime(int millis) {
    final diff = DateTime.now().millisecondsSinceEpoch - millis;
    if (diff < 60 * 1000) return '刚刚';
    if (diff < 60 * 60 * 1000) return '${diff ~/ (60 * 1000)} 分钟前';
    if (diff < 24 * 60 * 60 * 1000) return '${diff ~/ (60 * 60 * 1000)} 小时前';
    return '${diff ~/ (24 * 60 * 60 * 1000)} 天前';
  }
}

/// 聊天页（对齐旧版交互：右对齐用户气泡、左对齐回复、发送中可取消）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_container.dart';
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
  List<Message> _history = <Message>[];
  String _conversationId = '';
  bool _sending = false;
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
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    _input.clear();
    setState(() {
      _sending = true;
      _lastError = null;
    });
    final container = context.read<AppContainer>();
    _subscription = container.chat.send(_conversationId, text).listen(
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

  Future<void> _reload() async {
    final container = context.read<AppContainer>();
    final history = await container.messages.list(_conversationId);
    if (!mounted) return;
    setState(() => _history = history);
    _scrollToBottom();
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

  @override
  Widget build(BuildContext context) {
    final entries = <Widget>[
      for (final message in _history) _bubble(message),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('大肥鱼')),
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
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _input,
                    maxLines: null,
                    decoration: const InputDecoration(
                      hintText: '说点什么…',
                      border: OutlineInputBorder(),
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
        child: Text(text),
      ),
    );
  }

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

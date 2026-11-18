/// 聊天编排：持久化 → 记忆召回 → 组装 → 真实调用 → 状态机流转 → 记忆提取。
///
/// 状态机与旧版一致：draft → sending → sent / failed；用户取消 → canceled（保留已生成文本）。
/// 记忆提取失败不影响聊天主流程（静默降级）。
library;

import 'dart:async';

import 'package:uuid/uuid.dart' as uuid_pkg;

import '../../ai/memory_extraction_coordinator.dart';
import '../../ai/openai_compatible_provider.dart';
import '../../ai/prompt_composer.dart';
import '../../ai/recall_context_builder.dart';
import '../../core/memory/memory_extraction.dart';
import '../../core/time/current_time_context.dart';
import '../../data/repositories/config_repositories.dart';
import '../../data/repositories/conversation_repository.dart';
import '../../data/repositories/memory_repository.dart';
import '../../data/repositories/message_repository.dart';
import '../../domain/models/conversation.dart';
import '../../domain/models/message.dart';

/// 聊天运行事件（UI 据此刷新）。
sealed class ChatEvent {
  const ChatEvent();
}

class ChatDeltaEvent extends ChatEvent {
  const ChatDeltaEvent(this.messageId, this.accumulated, {this.reasoningTail});
  final String messageId;
  final String accumulated;
  final String? reasoningTail;
}

class ChatFinishedEvent extends ChatEvent {
  const ChatFinishedEvent(this.messageId);
  final String messageId;
}

class ChatFailedEvent extends ChatEvent {
  const ChatFailedEvent(this.messageId, this.error);
  final String messageId;
  final String error;
}

class ChatOrchestrator {
  ChatOrchestrator({
    required ConversationRepository conversations,
    required MessageRepository messages,
    required ModelConfigRepository modelConfigs,
    required PersonaRepository personas,
    required MemoryRepository memories,
    required this.extraction,
    required this.secureRead,
    RecallContextBuilder? recallBuilder,
    uuid_pkg.Uuid? uuid,
  })  : _conversations = conversations,
        _messages = messages,
        _modelConfigs = modelConfigs,
        _personas = personas,
        _memories = memories,
        _recallBuilder = recallBuilder,
        _uuid = uuid ?? const uuid_pkg.Uuid();

  final ConversationRepository _conversations;
  final MessageRepository _messages;
  final ModelConfigRepository _modelConfigs;
  final PersonaRepository _personas;
  final MemoryRepository _memories;

  /// 记忆召回（可空：未装配时只靠会话上下文）
  final RecallContextBuilder? _recallBuilder;

  /// 记忆提取（回复完成后异步执行，失败静默）
  final MemoryExtractionCoordinator extraction;

  /// 安全存储读取：keyRef → apiKey
  final Future<String?> Function(String keyRef) secureRead;
  final uuid_pkg.Uuid _uuid;

  StreamController<ChatEvent>? _active;
  String? _activeMessageId;

  bool get isRunning => _active != null && !_active!.isClosed;

  /// 确保主会话存在；返回会话 id。
  Future<String> ensureMainConversation() async {
    final existing = await _conversations.list();
    for (final conversation in existing) {
      if (conversation.kind == 'main') return conversation.id;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final conversation = Conversation(
      id: _uuid.v4(),
      title: '她',
      kind: 'main',
      createdAt: now,
      updatedAt: now,
    );
    await _conversations.upsert(conversation);
    return conversation.id;
  }

  /// 发送一条用户消息并请求回复。
  ///
  /// 返回事件流；取消生成调用 [cancel]。
  Stream<ChatEvent> send(String conversationId, String text) {
    final controller = StreamController<ChatEvent>();
    _active = controller;
    _run(conversationId, text, controller);
    return controller.stream;
  }

  /// 取消当前生成（保留已生成文本，置 canceled）。
  Future<void> cancel() async {
    final messageId = _activeMessageId;
    _active?.close();
    _active = null;
    if (messageId != null) {
      final message = await _messages.byId(messageId);
      if (message != null && message.status == MessageStatus.sending) {
        await _messages.update(message.copyWith(status: MessageStatus.canceled));
      }
    }
  }

  Future<void> _run(
    String conversationId,
    String text,
    StreamController<ChatEvent> controller,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      // 1. 持久化用户消息
      final userMessage = Message(
        id: _uuid.v4(),
        clientUuid: _uuid.v4(),
        conversationId: conversationId,
        role: MessageRole.user,
        kind: MessageKind.text,
        text: text,
        status: MessageStatus.sent,
        origin: MessageOrigin.user,
        createdAt: now,
        sentAt: now,
      );
      await _messages.insert(userMessage);
      await _conversations.touch(conversationId, updatedAt: now);

      // 2. 读取配置
      final config = await _modelConfigs.defaultConfig();
      if (config == null) {
        throw ProviderException('尚未配置模型，请先在设置中添加模型配置');
      }
      final apiKey = await secureRead(config.keyRef);
      if (apiKey == null || apiKey.isEmpty) {
        throw ProviderException('未找到 API 密钥，请重新保存模型配置');
      }

      // 3. 创建 assistant 消息占位
      final assistantId = _uuid.v4();
      _activeMessageId = assistantId;
      var assistant = Message(
        id: assistantId,
        clientUuid: _uuid.v4(),
        conversationId: conversationId,
        role: MessageRole.assistant,
        kind: MessageKind.text,
        text: '',
        status: MessageStatus.sending,
        origin: MessageOrigin.reply,
        replyToId: userMessage.id,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        modelConfigId: config.id,
      );
      await _messages.insert(assistant);

      // 4. 组装提示词：人格 → 时间上下文 → 记忆召回
      final history = <Map<String, String>>[];
      final priorMessages = await _messages.list(conversationId);
      for (final message in priorMessages) {
        if (message.id == userMessage.id || message.id == assistantId) continue;
        if (message.text.trim().isEmpty) continue;
        final role = message.role == MessageRole.assistant ? 'assistant' : 'user';
        history.add(<String, String>{'role': role, 'content': message.text});
      }

      final personaPrompt = await _personas.coreSystemPrompt();
      final recall = _recallBuilder;
      String? memoryBlock;
      if (recall != null) {
        final lines = await recall.recall(
          query: text,
          currentConversationId: conversationId,
        );
        if (lines.isNotEmpty) memoryBlock = lines.join('\n');
      }

      final provider = OpenAICompatibleProvider(
        baseUrl: config.baseUrl,
        modelId: config.modelId,
        apiKey: apiKey,
      );

      final accumulated = StringBuffer();
      await provider.stream(
        composeChatMessages(
          timeContext: CurrentTimeContext.describe(),
          personaPrompt: personaPrompt,
          memoryBlock: memoryBlock,
          history: history,
          current: text,
        ),
        onDelta: (delta) {
          if (delta.contentDelta.isNotEmpty) {
            accumulated.write(delta.contentDelta);
            if (!controller.isClosed) {
              controller.add(
                ChatDeltaEvent(assistantId, accumulated.toString()),
              );
            }
          }
        },
      );

      // 5. 落定状态
      final finalText = accumulated.toString();
      assistant = assistant.copyWith(
        text: finalText,
        status: finalText.isEmpty ? MessageStatus.failed : MessageStatus.sent,
        sentAt: DateTime.now().millisecondsSinceEpoch,
      );
      await _messages.update(assistant);
      await _conversations.touch(conversationId);
      if (!controller.isClosed) {
        if (finalText.isEmpty) {
          controller.add(ChatFailedEvent(assistantId, '模型返回了空回复'));
        } else {
          controller.add(ChatFinishedEvent(assistantId));
        }
      }

      // 6. 记忆提取（异步，失败静默；提取用同一个 provider）
      extraction.run(
        provider: provider,
        memories: _memories,
        input: MemoryExtractionInput(
          userText: text,
          assistantText: finalText,
        ),
        conversationId: conversationId,
        userMessageId: userMessage.id,
      );
    } catch (error) {
      final messageId = _activeMessageId;
      if (messageId != null) {
        final message = await _messages.byId(messageId);
        if (message != null && message.status == MessageStatus.sending) {
          await _messages.update(
            message.copyWith(text: message.text, status: MessageStatus.failed),
          );
        }
      }
      if (!controller.isClosed) {
        controller.add(ChatFailedEvent(messageId ?? '', error.toString()));
      }
    } finally {
      _activeMessageId = null;
      if (!controller.isClosed) {
        await controller.close();
      }
      _active = null;
    }
  }
}

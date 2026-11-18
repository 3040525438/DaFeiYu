/// 提示词组装（对齐 SwiftUI 版 PromptComposer/ContextComposer 的输出顺序）。
///
/// 最终发给模型的 messages 数组结构：
///   [system: 人格 + 时间上下文 + 记忆召回] + [历史 user/assistant…] + [当前 user]
library;

import '../core/time/current_time_context.dart';

/// 组装 system 提示词。
class PromptComposer {
  const PromptComposer._();

  /// - [personaPrompt]：核心人格 system_prompt（可空，导入人格前允许聊天）
  /// - [timeContext]：CurrentTimeContext.describe 输出
  /// - [memoryBlock]：记忆召回文本块（RecallContextBuilder 输出，可空）
  static String system({
    required String timeContext,
    String? personaPrompt,
    String? memoryBlock,
  }) {
    return [
      if (personaPrompt != null && personaPrompt.trim().isNotEmpty)
        '# 人格设定\n${personaPrompt.trim()}',
      '# 当前状态\n$timeContext',
      if (memoryBlock != null && memoryBlock.trim().isNotEmpty)
        '# 相关记忆\n${memoryBlock.trim()}\n'
            '以上记忆来自过往对话与观察，可能不完整；与当前对话冲突时以用户最新说法为准。',
    ].join('\n\n');
  }
}

/// 组装发给模型的完整 messages 数组。
class ChatMessages {
  const ChatMessages._();

  /// - [history]：已持久化的历史消息（role → user/assistant）
  /// - [current]：当前用户输入
  static List<Map<String, Object?>> build({
    required String system,
    required List<Map<String, Object?>> history,
    required String current,
  }) {
    return <Map<String, Object?>>[
      <String, String>{'role': 'system', 'content': system},
      ...history,
      <String, String>{'role': 'user', 'content': current},
    ];
  }
}

/// 便捷入口：一次组装完整请求消息。
///
/// history 的 content 允许 OpenAI 视觉多模态数组形态（P1 图片理解入口）。
List<Map<String, Object?>> composeChatMessages({
  required String timeContext,
  String? personaPrompt,
  String? memoryBlock,
  required List<Map<String, Object?>> history,
  required String current,
}) {
  return ChatMessages.build(
    system: PromptComposer.system(
      timeContext: timeContext,
      personaPrompt: personaPrompt,
      memoryBlock: memoryBlock,
    ),
    history: history,
    current: current,
  );
}

/// 生成当前时间上下文文本（转发到 CurrentTimeContext，供上层一处调用）。
String describeNow({DateTime? now}) => CurrentTimeContext.describe(now: now);

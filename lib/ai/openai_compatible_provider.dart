/// OpenAI 兼容 provider（对齐 SwiftUI 版请求体：chat/completions，流式 + 非流式）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// 一次补全请求的非流式结果。
class ChatCompletion {
  const ChatCompletion({required this.content, this.reasoning});

  final String content;

  /// 思考过程（provider 返回 reasoning_content 时保留）
  final String? reasoning;
}

/// 流式增量。
class ChatDelta {
  const ChatDelta({required this.contentDelta, this.reasoningDelta});

  final String contentDelta;
  final String? reasoningDelta;
}

/// Provider 错误（带 HTTP 状态与响应体摘要，便于定位）。
class ProviderException implements Exception {
  ProviderException(this.message, {this.statusCode, this.responseBody});

  final String message;
  final int? statusCode;
  final String? responseBody;

  @override
  String toString() {
    if (statusCode != null) {
      return 'ProviderException($statusCode): $message';
    }
    return 'ProviderException: $message';
  }
}

class OpenAICompatibleProvider {
  OpenAICompatibleProvider({
    required this.baseUrl,
    required this.modelId,
    required this.apiKey,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String modelId;
  final String apiKey;
  final http.Client _client;

  Uri get _chatUri {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$base/chat/completions');
  }

  Map<String, String> get _headers => <String, String>{
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      };

  /// 请求体（temperature 默认省略，由服务端默认值决定，与旧版一致）。
  Map<String, Object?> buildBody(
    List<Map<String, String>> messages, {
    bool stream = false,
    Map<String, Object?> extra = const <String, Object?>{},
  }) {
    return <String, Object?>{
      'model': modelId,
      'messages': messages,
      'stream': stream,
      if (stream) 'stream_options': <String, Object?>{'include_usage': false},
      ...extra,
    };
  }

  /// 非流式补全。
  Future<ChatCompletion> complete(
    List<Map<String, String>> messages, {
    Map<String, Object?> extra = const <String, Object?>{},
  }) async {
    final response = await _client
        .post(_chatUri, headers: _headers, body: jsonEncode(buildBody(messages, stream: false, extra: extra)))
        .timeout(const Duration(minutes: 3));
    if (response.statusCode != 200) {
      throw ProviderException(
        '补全请求失败',
        statusCode: response.statusCode,
        responseBody: _excerpt(response.body),
      );
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, Object?>) {
      throw ProviderException('响应不是 JSON 对象', responseBody: _excerpt(response.body));
    }
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      throw ProviderException('响应缺少 choices', responseBody: _excerpt(response.body));
    }
    final first = choices.first;
    if (first is! Map<String, Object?>) {
      throw ProviderException('choices[0] 结构异常');
    }
    final message = first['message'];
    final content = message is Map<String, Object?> ? (message['content'] as String? ?? '') : '';
    final reasoning = message is Map<String, Object?>
        ? (message['reasoning_content'] as String? ?? message['reasoning'] as String?)
        : null;
    return ChatCompletion(content: content, reasoning: reasoning);
  }

  /// 流式补全：逐 delta 回调；返回拼接后的完整文本。
  Future<String> stream(
    List<Map<String, String>> messages, {
    required void Function(ChatDelta delta) onDelta,
    Map<String, Object?> extra = const <String, Object?>{},
  }) async {
    final request = http.Request('POST', _chatUri)
      ..headers.addAll(_headers)
      ..body = jsonEncode(buildBody(messages, stream: true, extra: extra));
    final response = await _client.send(request).timeout(const Duration(minutes: 3));
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw ProviderException(
        '流式请求失败',
        statusCode: response.statusCode,
        responseBody: _excerpt(body),
      );
    }

    final buffer = StringBuffer();
    final reasoningBuffer = StringBuffer();
    await for (final line in response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || !trimmed.startsWith('data:')) continue;
      final payload = trimmed.substring(5).trim();
      if (payload == '[DONE]') break;
      final Object? decoded;
      try {
        decoded = jsonDecode(payload);
      } on FormatException {
        continue; // 跳过非 JSON 行（部分网关会插入注释）
      }
      if (decoded is! Map<String, Object?>) continue;
      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty) continue;
      final first = choices.first;
      if (first is! Map<String, Object?>) continue;
      final delta = first['delta'];
      if (delta is! Map<String, Object?>) continue;
      final content = delta['content'];
      final reasoning = delta['reasoning_content'] ?? delta['reasoning'];
      if (reasoning is String && reasoning.isNotEmpty) {
        reasoningBuffer.write(reasoning);
        onDelta(ChatDelta(contentDelta: '', reasoningDelta: reasoning));
      }
      if (content is String && content.isNotEmpty) {
        buffer.write(content);
        onDelta(ChatDelta(contentDelta: content, reasoningDelta: null));
      }
    }
    return buffer.toString();
  }

  String _excerpt(String body) {
    final text = body.trim();
    return text.length <= 300 ? text : '${text.substring(0, 300)}…';
  }

  void close() {
    _client.close();
  }
}

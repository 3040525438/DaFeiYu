/// 消息模型（与 SwiftUI 版 `Message` 及 `messages` 表对齐）。
///
/// 状态机与旧版一致：`draft → sending → sent / failed`，
/// 用户取消生成时置 `canceled` 并保留已生成文本。
library;

enum MessageRole {
  user,
  assistant,
  system,
  event;

  static MessageRole fromWire(String? value) {
    return MessageRole.values.firstWhere(
      (MessageRole role) => role.name == value,
      orElse: () => MessageRole.user,
    );
  }
}

enum MessageKind {
  text,
  image,
  voice,
  mixed,
  proactive,
  sticker;

  static MessageKind fromWire(String? value) {
    return MessageKind.values.firstWhere(
      (MessageKind kind) => kind.name == value,
      orElse: () => MessageKind.text,
    );
  }
}

enum MessageStatus {
  draft,
  sending,
  sent,
  failed,
  recalled,
  canceled;

  static MessageStatus fromWire(String? value) {
    return MessageStatus.values.firstWhere(
      (MessageStatus status) => status.name == value,
      orElse: () => MessageStatus.draft,
    );
  }
}

enum MessageOrigin {
  user,
  reply,
  proactive,
  imported,
  system;

  static MessageOrigin fromWire(String? value) {
    return MessageOrigin.values.firstWhere(
      (MessageOrigin origin) => origin.name == value,
      orElse: () => MessageOrigin.user,
    );
  }
}

class Message {
  const Message({
    required this.id,
    required this.clientUuid,
    required this.conversationId,
    required this.role,
    required this.kind,
    required this.text,
    required this.status,
    required this.origin,
    required this.createdAt,
    this.replyToId,
    this.sentAt,
    this.modelConfigId,
    this.emotionStateId,
    this.deletedAt,
    this.groupId,
    this.seqInGroup,
    this.editedAt,
    this.editCount = 0,
    this.revokedAt,
    this.revokeReason,
    this.isFavorite = false,
    this.isImportant = false,
    this.importantAt,
  });

  final String id;

  /// 幂等键：重复写入由唯一索引拦截
  final String clientUuid;
  final String conversationId;
  final MessageRole role;
  final MessageKind kind;
  final String text;
  final MessageStatus status;
  final MessageOrigin origin;
  final String? replyToId;

  /// 用户视角时间（毫秒 UTC）
  final int createdAt;

  /// 实际写入完成时间
  final int? sentAt;
  final String? modelConfigId;
  final String? emotionStateId;
  final int? deletedAt;
  final String? groupId;
  final int? seqInGroup;
  final int? editedAt;
  final int editCount;
  final int? revokedAt;
  final String? revokeReason;
  final bool isFavorite;

  /// v14 新增列；旧备份里没有该列时为 false
  final bool isImportant;
  final int? importantAt;

  bool get isDeleted => deletedAt != null;
  bool get isRevoked => revokedAt != null;

  /// 系统注入、界面不渲染的隐藏指令
  bool get isHiddenInstruction => role == MessageRole.user && origin == MessageOrigin.system;

  /// 可被用户取消后继续写的 assistant 消息
  bool get canContinueWriting =>
      role == MessageRole.assistant &&
      deletedAt == null &&
      revokedAt == null &&
      text.trim().isNotEmpty &&
      (status == MessageStatus.sent || status == MessageStatus.canceled);

  factory Message.fromMap(Map<String, Object?> row) {
    return Message(
      id: row['id']! as String,
      clientUuid: (row['client_uuid'] as String?) ?? '',
      conversationId: (row['conversation_id'] as String?) ?? '',
      role: MessageRole.fromWire(row['role'] as String?),
      kind: MessageKind.fromWire(row['kind'] as String?),
      text: (row['text'] as String?) ?? '',
      status: MessageStatus.fromWire(row['status'] as String?),
      origin: MessageOrigin.fromWire(row['origin'] as String?),
      replyToId: row['reply_to_id'] as String?,
      createdAt: (row['created_at'] as num?)?.toInt() ?? 0,
      sentAt: (row['sent_at'] as num?)?.toInt(),
      modelConfigId: row['model_config_id'] as String?,
      emotionStateId: row['emotion_state_id'] as String?,
      deletedAt: (row['deleted_at'] as num?)?.toInt(),
      groupId: row['group_id'] as String?,
      seqInGroup: (row['seq_in_group'] as num?)?.toInt(),
      editedAt: (row['edited_at'] as num?)?.toInt(),
      editCount: (row['edit_count'] as num?)?.toInt() ?? 0,
      revokedAt: (row['revoked_at'] as num?)?.toInt(),
      revokeReason: row['revoke_reason'] as String?,
      isFavorite: ((row['is_favorite'] as num?)?.toInt() ?? 0) == 1,
      isImportant: ((row['is_important'] as num?)?.toInt() ?? 0) == 1,
      importantAt: (row['important_at'] as num?)?.toInt(),
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'id': id,
      'client_uuid': clientUuid,
      'conversation_id': conversationId,
      'role': role.name,
      'kind': kind.name,
      'text': text,
      'status': status.name,
      'origin': origin.name,
      'reply_to_id': replyToId,
      'created_at': createdAt,
      'sent_at': sentAt,
      'model_config_id': modelConfigId,
      'emotion_state_id': emotionStateId,
      'deleted_at': deletedAt,
      'group_id': groupId,
      'seq_in_group': seqInGroup,
      'edited_at': editedAt,
      'edit_count': editCount,
      'revoked_at': revokedAt,
      'revoke_reason': revokeReason,
      'is_favorite': isFavorite ? 1 : 0,
      'is_important': isImportant ? 1 : 0,
      'important_at': importantAt,
    };
  }

  Message copyWith({
    String? text,
    MessageStatus? status,
    int? sentAt,
    int? editedAt,
    int? editCount,
    int? deletedAt,
    bool? isFavorite,
    bool? isImportant,
    int? importantAt,
  }) {
    return Message(
      id: id,
      clientUuid: clientUuid,
      conversationId: conversationId,
      role: role,
      kind: kind,
      text: text ?? this.text,
      status: status ?? this.status,
      origin: origin,
      replyToId: replyToId,
      createdAt: createdAt,
      sentAt: sentAt ?? this.sentAt,
      modelConfigId: modelConfigId,
      emotionStateId: emotionStateId,
      deletedAt: deletedAt ?? this.deletedAt,
      groupId: groupId,
      seqInGroup: seqInGroup,
      editedAt: editedAt ?? this.editedAt,
      editCount: editCount ?? this.editCount,
      revokedAt: revokedAt,
      revokeReason: revokeReason,
      isFavorite: isFavorite ?? this.isFavorite,
      isImportant: isImportant ?? this.isImportant,
      importantAt: importantAt ?? this.importantAt,
    );
  }
}

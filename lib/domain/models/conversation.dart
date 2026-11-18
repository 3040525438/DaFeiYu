/// 会话模型（与 SwiftUI 版 `Conversation` 及 `conversations` 表对齐）。
library;

class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.kind,
    required this.createdAt,
    required this.updatedAt,
    this.archivedAt,
  });

  final String id;
  final String title;

  /// 会话类型：`main` 为主会话；`proactive` / `imported` 用于来源标识
  final String kind;

  /// 创建时间（毫秒 UTC）
  final int createdAt;

  /// 最近更新时间（毫秒 UTC）
  final int updatedAt;

  /// 归档时间（毫秒 UTC），null 表示未归档
  final int? archivedAt;

  bool get isArchived => archivedAt != null;

  factory Conversation.fromMap(Map<String, Object?> row) {
    return Conversation(
      id: row['id']! as String,
      title: (row['title'] as String?) ?? '',
      kind: (row['kind'] as String?) ?? 'main',
      createdAt: (row['created_at'] as num?)?.toInt() ?? 0,
      updatedAt: (row['updated_at'] as num?)?.toInt() ?? 0,
      archivedAt: (row['archived_at'] as num?)?.toInt(),
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'id': id,
      'title': title,
      'kind': kind,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'archived_at': archivedAt,
    };
  }

  Conversation copyWith({String? title, int? updatedAt, int? archivedAt}) {
    return Conversation(
      id: id,
      title: title ?? this.title,
      kind: kind,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      archivedAt: archivedAt ?? this.archivedAt,
    );
  }
}

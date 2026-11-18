/// 日记领域模型（对齐 SwiftUI 版 DFCore DiaryEntry / DiaryUpsert）。
///
/// 硬约束（W6 / D34 / D72）：
/// - 一天一篇（entry_date 唯一，软删后可重建）；
/// - 双方编辑都必须留全量版本快照；
/// - 关系变化只作为观察写入，`relationshipChangeConfirmed` 由用户显式确认。
library;

/// 日记条目（`diary_entries` 一行）
class DiaryEntry {
  DiaryEntry({
    required this.id,
    required this.entryDate,
    required this.title,
    required this.content,
    this.moodCode,
    required this.source,
    this.generatedBy,
    required this.isUserEdited,
    this.memoryId,
    required this.sharedExperience,
    required this.observation,
    required this.feeling,
    required this.relationshipChange,
    required this.relationshipChangeConfirmed,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  final String id;
  /// yyyy-MM-dd（UTC+8）
  final String entryDate;
  final String title;
  final String content;
  /// 六码白名单：calm / warm / happy / tired / low / excited
  final String? moodCode;
  /// manual / auto / migration
  final String source;
  final String? generatedBy;
  final bool isUserEdited;
  final String? memoryId;
  final String sharedExperience;
  final String observation;
  final String feeling;
  final String relationshipChange;
  final bool relationshipChangeConfirmed;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;

  /// 用户手写 / 编辑过 / 迁移来的日记不允许被自动生成覆盖
  bool get isProtectedFromAutoOverwrite => isUserEdited || source != 'auto';

  static DiaryEntry fromRow(Map<String, Object?> row) => DiaryEntry(
    id: row['id']! as String,
    entryDate: row['entry_date']! as String,
    title: (row['title'] as String?) ?? '',
    content: row['content']! as String,
    moodCode: row['mood_code'] as String?,
    source: (row['source'] as String?) ?? 'manual',
    generatedBy: row['generated_by'] as String?,
    isUserEdited: ((row['is_user_edited'] as int?) ?? 0) != 0,
    memoryId: row['memory_id'] as String?,
    sharedExperience: (row['shared_experience'] as String?) ?? '',
    observation: (row['observation'] as String?) ?? '',
    feeling: (row['feeling'] as String?) ?? '',
    relationshipChange: (row['relationship_change'] as String?) ?? '',
    relationshipChangeConfirmed: ((row['relationship_change_confirmed'] as int?) ?? 0) != 0,
    createdAt: (row['created_at'] as int?) ?? 0,
    updatedAt: (row['updated_at'] as int?) ?? 0,
    deletedAt: row['deleted_at'] as int?,
  );
}

/// 日记写入请求（新增或按天覆盖）
class DiaryUpsert {
  DiaryUpsert({
    required this.entryDate,
    required this.title,
    required this.content,
    this.moodCode,
    required this.source,
    this.generatedBy,
    required this.isUserEdited,
    this.memoryId,
    required this.sharedExperience,
    required this.observation,
    required this.feeling,
    required this.relationshipChange,
    required this.relationshipChangeConfirmed,
    required this.changeReason,
    required this.changedBy,
  });

  final String entryDate;
  final String title;
  final String content;
  final String? moodCode;
  final String source;
  final String? generatedBy;
  final bool isUserEdited;
  final String? memoryId;
  final String sharedExperience;
  final String observation;
  final String feeling;
  final String relationshipChange;
  final bool relationshipChangeConfirmed;
  /// 留痕到 diary_entry_versions.change_reason
  final String changeReason;
  /// 只允许 user / ai / migration
  final String changedBy;
}

/// 日记错误
class DiaryError implements Exception {
  DiaryError(this.message);
  final String message;

  static DiaryError get emptyContent => DiaryError('日记正文不能为空');
  static DiaryError invalidDate(String date) => DiaryError('日记日期非法：$date');
  static DiaryError invalidEditor(String editor) => DiaryError('编辑者非法：$editor');
  static DiaryError get notFound => DiaryError('日记不存在');

  @override
  String toString() => message;
}

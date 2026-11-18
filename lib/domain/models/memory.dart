/// 记忆领域模型（memories 表最终态全列，与 SwiftUI 版 v1 基表 + v2 扩展列对齐）。
library;

/// 记忆记录。
class MemoryRecord {
  MemoryRecord({
    required this.id,
    required this.type,
    required this.title,
    required this.content,
    this.importance = 'normal',
    this.salience = 0.5,
    this.confidence = 0.5,
    this.validFrom,
    this.validTo,
    this.status = 'active',
    required this.firstSeenAt,
    this.lastRecalledAt,
    this.recallCount = 0,
    this.scope = 'shared',
    this.layer = 'semantic',
    this.category = 'fact',
    this.sourceKind = 'real_interaction',
    this.epistemicStatus = 'observed',
    this.version = 1,
    this.subjectEntityId,
    this.dedupeKey,
    this.heat = 'warm',
    this.archivedAt,
    this.deletedAt,
    this.createdAt = 0,
    this.updatedAt = 0,
    this.importanceScore,
    this.importanceSource = 'unparsed',
    this.importanceSourceAt,
    this.classificationStatus = 'pending',
    this.originalExternalId,
    this.originalContent,
    this.originalCreatedAt,
    this.importBatchId,
    this.classificationEvidenceJson = '[]',
    this.classifiedBy,
    this.classifiedAt,
  });

  factory MemoryRecord.fromMap(Map<String, Object?> map) {
    return MemoryRecord(
      id: map['id']! as String,
      type: map['type']! as String,
      title: map['title']! as String,
      content: map['content']! as String,
      importance: (map['importance'] ?? 'normal') as String,
      salience: ((map['salience'] ?? 0.5) as num).toDouble(),
      confidence: ((map['confidence'] ?? 0.5) as num).toDouble(),
      validFrom: map['valid_from'] as int?,
      validTo: map['valid_to'] as int?,
      status: (map['status'] ?? 'active') as String,
      firstSeenAt: (map['first_seen_at'] ?? 0) as int,
      lastRecalledAt: map['last_recalled_at'] as int?,
      recallCount: ((map['recall_count'] ?? 0) as num).toInt(),
      scope: (map['scope'] ?? 'shared') as String,
      layer: (map['layer'] ?? 'semantic') as String,
      category: (map['category'] ?? 'fact') as String,
      sourceKind: (map['source_kind'] ?? 'real_interaction') as String,
      epistemicStatus: (map['epistemic_status'] ?? 'observed') as String,
      version: ((map['version'] ?? 1) as num).toInt(),
      subjectEntityId: map['subject_entity_id'] as String?,
      dedupeKey: map['dedupe_key'] as String?,
      heat: (map['heat'] ?? 'warm') as String,
      archivedAt: map['archived_at'] as int?,
      deletedAt: map['deleted_at'] as int?,
      createdAt: ((map['created_at'] ?? 0) as num).toInt(),
      updatedAt: ((map['updated_at'] ?? 0) as num).toInt(),
      importanceScore: (map['importance_score'] as num?)?.toDouble(),
      importanceSource: (map['importance_source'] ?? 'unparsed') as String,
      importanceSourceAt: map['importance_source_at'] as int?,
      classificationStatus: (map['classification_status'] ?? 'pending') as String,
      originalExternalId: map['original_external_id'] as String?,
      originalContent: map['original_content'] as String?,
      originalCreatedAt: map['original_created_at'] as int?,
      importBatchId: map['import_batch_id'] as String?,
      classificationEvidenceJson: (map['classification_evidence_json'] ?? '[]') as String,
      classifiedBy: map['classified_by'] as String?,
      classifiedAt: map['classified_at'] as int?,
    );
  }

  final String id;
  final String type;
  final String title;
  final String content;
  final String importance;
  final double salience;
  final double confidence;
  final int? validFrom;
  final int? validTo;
  final String status;
  final int firstSeenAt;
  final int? lastRecalledAt;
  final int recallCount;

  // v2 扩展列
  final String scope;
  final String layer;
  final String category;
  final String sourceKind;
  final String epistemicStatus;
  final int version;
  final String? subjectEntityId;
  final String? dedupeKey;
  final String heat;
  final int? archivedAt;
  final int? deletedAt;
  final int createdAt;
  final int updatedAt;
  final double? importanceScore;
  final String importanceSource;
  final int? importanceSourceAt;
  final String classificationStatus;
  final String? originalExternalId;
  final String? originalContent;
  final int? originalCreatedAt;
  final String? importBatchId;
  final String classificationEvidenceJson;
  final String? classifiedBy;
  final int? classifiedAt;

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'id': id,
      'type': type,
      'title': title,
      'content': content,
      'importance': importance,
      'salience': salience,
      'confidence': confidence,
      'valid_from': validFrom,
      'valid_to': validTo,
      'status': status,
      'first_seen_at': firstSeenAt,
      'last_recalled_at': lastRecalledAt,
      'recall_count': recallCount,
      'scope': scope,
      'layer': layer,
      'category': category,
      'source_kind': sourceKind,
      'epistemic_status': epistemicStatus,
      'version': version,
      'subject_entity_id': subjectEntityId,
      'dedupe_key': dedupeKey,
      'heat': heat,
      'archived_at': archivedAt,
      'deleted_at': deletedAt,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'importance_score': importanceScore,
      'importance_source': importanceSource,
      'importance_source_at': importanceSourceAt,
      'classification_status': classificationStatus,
      'original_external_id': originalExternalId,
      'original_content': originalContent,
      'original_created_at': originalCreatedAt,
      'import_batch_id': importBatchId,
      'classification_evidence_json': classificationEvidenceJson,
      'classified_by': classifiedBy,
      'classified_at': classifiedAt,
    };
  }

  MemoryRecord copyWith(Map<String, Object?> overrides) {
    final map = toMap()..addAll(overrides);
    return MemoryRecord.fromMap(map);
  }
}

/// 模型配置模型（对应 `model_configs` 表；密钥经安全存储按 key_ref 取出）。
library;

class ModelConfig {
  const ModelConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.modelId,
    required this.keyRef,
    this.isDefault = false,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String baseUrl;
  final String modelId;

  /// 安全存储中的键引用（不落库）
  final String keyRef;
  final bool isDefault;
  final int createdAt;
  final int updatedAt;

  factory ModelConfig.fromMap(Map<String, Object?> row) {
    return ModelConfig(
      id: row['id']! as String,
      name: (row['name'] as String?) ?? '',
      baseUrl: (row['base_url'] as String?) ?? '',
      modelId: (row['model_id'] as String?) ?? '',
      keyRef: (row['key_ref'] as String?) ?? '',
      isDefault: ((row['is_default'] as num?)?.toInt() ?? 0) == 1,
      createdAt: (row['created_at'] as num?)?.toInt() ?? 0,
      updatedAt: (row['updated_at'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'id': id,
      'name': name,
      'base_url': baseUrl,
      'model_id': modelId,
      'key_ref': keyRef,
      'is_default': isDefault ? 1 : 0,
      'created_at': createdAt,
      'updated_at': updatedAt,
    };
  }
}

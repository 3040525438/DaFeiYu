/// 人格模型（personas + persona_items 的聚合视图）。
library;

/// 单条人格条目（persona_items 一行）。
class PersonaItem {
  const PersonaItem({
    required this.id,
    required this.section,
    required this.key,
    required this.value,
    this.confidence = 1.0,
    this.weight = 1.0,
    this.source = 'user',
  });

  final String id;
  final String section;
  final String key;
  final String value;
  final double confidence;
  final double weight;
  final String source;

  factory PersonaItem.fromMap(Map<String, Object?> row) {
    return PersonaItem(
      id: row['id']! as String,
      section: (row['section'] as String?) ?? '',
      key: (row['key'] as String?) ?? '',
      value: (row['value'] as String?) ?? '',
      confidence: ((row['confidence'] as num?)?.toDouble()) ?? 1.0,
      weight: ((row['weight'] as num?)?.toDouble()) ?? 1.0,
      source: (row['source'] as String?) ?? 'user',
    );
  }
}

class Persona {
  const Persona({
    required this.id,
    required this.kind,
    required this.name,
    required this.currentVersion,
    required this.items,
  });

  final String id;
  final String kind;
  final String name;
  final int currentVersion;
  final List<PersonaItem> items;

  factory Persona.fromMaps(Map<String, Object?> personaRow, List<Map<String, Object?>> itemRows) {
    return Persona(
      id: personaRow['id']! as String,
      kind: (personaRow['kind'] as String?) ?? 'core',
      name: (personaRow['name'] as String?) ?? '',
      currentVersion: (personaRow['current_version'] as num?)?.toInt() ?? 1,
      items: itemRows.map(PersonaItem.fromMap).toList(),
    );
  }

  /// 外围人格条目按 section 分组（核心人格之外的展示与注入用）。
  Map<String, List<PersonaItem>> get itemsBySection {
    final grouped = <String, List<PersonaItem>>{};
    for (final item in items) {
      grouped.putIfAbsent(item.section, () => <PersonaItem>[]).add(item);
    }
    return grouped;
  }
}

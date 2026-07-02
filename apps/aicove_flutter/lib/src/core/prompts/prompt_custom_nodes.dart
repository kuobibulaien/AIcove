import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class PromptCustomNode {
  const PromptCustomNode({
    required this.id,
    required this.title,
    required this.category,
    required this.template,
    this.description = '',
    this.variables = const <String>[],
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? updatedAt,
        updatedAt = updatedAt ?? createdAt;

  final String id;
  final String title;
  final String category;
  final String description;
  final String template;
  final List<String> variables;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory PromptCustomNode.fromJson(Map<String, Object?> json) {
    final id = _readString(json['id']);
    return PromptCustomNode(
      id: id,
      title: _readString(json['title'], fallback: id),
      category: _readString(json['category'], fallback: 'custom'),
      description: _readString(json['description']),
      template: _readString(json['template']),
      variables: _readStringList(json['variables']),
      createdAt: _readDateTime(json['createdAt']),
      updatedAt: _readDateTime(json['updatedAt']),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'title': title,
      'category': category,
      'description': description,
      'template': template,
      'variables': variables,
      'createdAt': createdAt?.toIso8601String(),
      'updatedAt': updatedAt?.toIso8601String(),
    };
  }
}

class PromptCustomNodeStore {
  const PromptCustomNodeStore();

  static const PromptCustomNodeStore instance = PromptCustomNodeStore();
  static const String storageKey = 'aicove.prompt_custom_nodes.v1';

  Future<List<PromptCustomNode>> load({SharedPreferences? preferences}) async {
    final prefs = preferences ?? await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    return _decode(raw);
  }

  Future<void> addNode(
    PromptCustomNode node, {
    Set<String> reservedIds = const <String>{},
    SharedPreferences? preferences,
  }) async {
    final normalized = _normalize(node);
    if (reservedIds.contains(normalized.id)) {
      throw ArgumentError('不能使用内置默认节点 ID');
    }
    final prefs = preferences ?? await SharedPreferences.getInstance();
    final nodes = _decode(prefs.getString(storageKey));
    if (nodes.any((item) => item.id == normalized.id)) {
      throw ArgumentError('自定义节点 ID 已存在');
    }
    await _persist(prefs, <PromptCustomNode>[...nodes, normalized]);
  }

  Future<void> clearForTesting({SharedPreferences? preferences}) async {
    final prefs = preferences ?? await SharedPreferences.getInstance();
    await prefs.remove(storageKey);
  }

  static PromptCustomNode _normalize(PromptCustomNode node) {
    final now = DateTime.now();
    final id = node.id.trim();
    final title = node.title.trim();
    final template = node.template.trim();
    if (id.isEmpty) {
      throw ArgumentError('请输入节点 ID');
    }
    if (title.isEmpty) {
      throw ArgumentError('请输入标题');
    }
    if (template.isEmpty) {
      throw ArgumentError('请输入提示词模板');
    }
    return PromptCustomNode(
      id: id,
      title: title,
      category: node.category.trim().isEmpty ? 'custom' : node.category.trim(),
      description: node.description.trim(),
      template: template,
      variables: <String>[
        for (final variable in node.variables)
          if (variable.trim().isNotEmpty) variable.trim(),
      ],
      createdAt: node.createdAt ?? now,
      updatedAt: now,
    );
  }

  static List<PromptCustomNode> _decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return const <PromptCustomNode>[];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <PromptCustomNode>[];
      return decoded
          .whereType<Map>()
          .map((entry) => PromptCustomNode.fromJson(
                Map<String, Object?>.from(entry),
              ))
          .where((node) => node.id.trim().isNotEmpty)
          .toList(growable: false)
        ..sort((a, b) => a.id.compareTo(b.id));
    } catch (_) {
      return const <PromptCustomNode>[];
    }
  }

  static Future<void> _persist(
    SharedPreferences prefs,
    List<PromptCustomNode> nodes,
  ) async {
    await prefs.setString(
      storageKey,
      jsonEncode(<Map<String, Object?>>[
        for (final node in nodes) node.toJson(),
      ]),
    );
  }
}

String _readString(Object? value, {String fallback = ''}) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}

List<String> _readStringList(Object? value) {
  if (value is! List) return const <String>[];
  return <String>[
    for (final item in value)
      if (item != null && item.toString().trim().isNotEmpty)
        item.toString().trim(),
  ];
}

DateTime? _readDateTime(Object? value) {
  if (value == null) return null;
  return DateTime.tryParse(value.toString());
}

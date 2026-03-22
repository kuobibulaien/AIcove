library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

class PromptTagSemanticsEntry {
  const PromptTagSemanticsEntry({
    required this.id,
    required this.tagName,
    required this.prompt,
    this.enabled = true,
  });

  final String id;
  final String tagName;
  final String prompt;
  final bool enabled;

  String get trimmedPrompt => prompt.trim();

  bool get isActive => enabled && trimmedPrompt.isNotEmpty;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'tagName': tagName,
      'enabled': enabled,
      'active': isActive,
      'prompt': trimmedPrompt,
    };
  }
}

class PromptTagSemanticsSnapshot {
  const PromptTagSemanticsSnapshot({
    required this.entries,
    this.leadIn,
  });

  final List<PromptTagSemanticsEntry> entries;
  final String? leadIn;

  List<PromptTagSemanticsEntry> get activeEntries => <PromptTagSemanticsEntry>[
        for (final entry in entries)
          if (entry.isActive) entry,
      ];

  String get mergedPrompt {
    final parts = <String>[];
    final leadInText = leadIn?.trim() ?? '';
    if (leadInText.isNotEmpty) {
      parts.add(leadInText);
    }
    for (final entry in activeEntries) {
      parts.add(entry.trimmedPrompt);
    }
    return parts.join('\n\n');
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'leadIn': leadIn?.trim() ?? '',
      'entries': <Map<String, dynamic>>[
        for (final entry in entries) entry.toJson(),
      ],
      'mergedPrompt': mergedPrompt,
    };
  }
}

class PromptTagSemanticsService {
  const PromptTagSemanticsService();

  static const String defaultLeadIn =
      '以下是当前会话启用的特殊标签说明。请理解这些标签的含义和规则，但不要把这些说明原样复述给用户。';

  PromptTagSemanticsSnapshot buildSnapshot(
    Iterable<PromptTagSemanticsEntry> entries, {
    String? leadIn = defaultLeadIn,
  }) {
    return PromptTagSemanticsSnapshot(
      entries: <PromptTagSemanticsEntry>[...entries],
      leadIn: leadIn,
    );
  }

  String buildMergedPrompt(
    Iterable<PromptTagSemanticsEntry> entries, {
    String? leadIn = defaultLeadIn,
  }) {
    return buildSnapshot(entries, leadIn: leadIn).mergedPrompt;
  }
}

final promptTagSemanticsServiceProvider = Provider<PromptTagSemanticsService>(
  (ref) => const PromptTagSemanticsService(),
);

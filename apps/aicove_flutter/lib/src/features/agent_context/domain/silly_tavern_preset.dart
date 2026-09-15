library;

import 'silly_tavern_world_book.dart';

enum SillyTavernParameterStatus {
  applied,
  notApplicable,
  intentionallyUnsupported,
}

class SillyTavernParameterCompatibility {
  final String field;
  final SillyTavernParameterStatus status;
  final String reason;

  const SillyTavernParameterCompatibility({
    required this.field,
    required this.status,
    required this.reason,
  });

  Map<String, dynamic> toTraceJson() => <String, dynamic>{
    'field': field,
    'status': status.name,
    'reason': reason,
  };
}

class SillyTavernRegexScript {
  final String id;
  final String name;
  final String source;
  final bool disabled;
  final bool runOnEdit;
  final String findRegex;
  final String replaceString;
  final List<String> trimStrings;
  final List<int> placements;
  final int substituteRegex;
  final int? minDepth;
  final int? maxDepth;
  final bool markdownOnly;
  final bool promptOnly;

  const SillyTavernRegexScript({
    required this.id,
    required this.name,
    required this.source,
    required this.disabled,
    required this.runOnEdit,
    required this.findRegex,
    required this.replaceString,
    required this.trimStrings,
    required this.placements,
    required this.substituteRegex,
    required this.minDepth,
    required this.maxDepth,
    required this.markdownOnly,
    required this.promptOnly,
  });

  Map<String, dynamic> toWorkerJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'source': source,
    'disabled': disabled,
    'findRegex': findRegex,
    'replaceString': replaceString,
    'trimStrings': trimStrings,
    'placements': placements,
    'substituteRegex': substituteRegex,
    'minDepth': minDepth,
    'maxDepth': maxDepth,
    'markdownOnly': markdownOnly,
    'promptOnly': promptOnly,
  };
}

/// SillyTavern Chat Completion 预设中的单个 prompt。
class SillyTavernPrompt {
  final String identifier;
  final String name;
  final String role;
  final String content;
  final bool marker;
  final bool systemPrompt;
  final int injectionPosition;
  final int injectionDepth;
  final int injectionOrder;
  final List<String> injectionTriggers;
  final int? attachIndex;
  final String? attachRole;
  final String? attachSide;

  const SillyTavernPrompt({
    required this.identifier,
    required this.name,
    required this.role,
    required this.content,
    required this.marker,
    required this.systemPrompt,
    required this.injectionPosition,
    required this.injectionDepth,
    required this.injectionOrder,
    required this.injectionTriggers,
    this.attachIndex,
    this.attachRole,
    this.attachSide,
  });

  bool get isAbsoluteInjection => injectionPosition == 1;
  bool get hasAttachment =>
      attachIndex != null && attachRole != null && attachSide != null;
}

class SillyTavernPromptOrderEntry {
  final String identifier;
  final bool enabled;

  const SillyTavernPromptOrderEntry({
    required this.identifier,
    required this.enabled,
  });
}

class SillyTavernPromptOrderGroup {
  final int sourceIndex;
  final String? characterId;
  final List<SillyTavernPromptOrderEntry> entries;

  const SillyTavernPromptOrderGroup({
    required this.sourceIndex,
    required this.characterId,
    required this.entries,
  });
}

/// 已校验、可直接参与运行时组装的 SillyTavern 预设。
class SillyTavernPreset {
  final String id;
  final String name;
  final String sourceFileName;
  final DateTime importedAt;
  final String sourceFormat;
  final List<SillyTavernPrompt> prompts;
  final List<SillyTavernPromptOrderGroup> promptOrderGroups;
  final int selectedOrderIndex;
  final int regexScriptCount;
  final List<SillyTavernRegexScript> regexScripts;
  final bool regexAuthorized;
  final List<SillyTavernParameterCompatibility> parameterCompatibility;
  final double? temperature;
  final double? topP;
  final int? topK;
  final double? minP;
  final double? topA;
  final double? repetitionPenalty;
  final double? frequencyPenalty;
  final double? presencePenalty;
  final int? seed;
  final int? maxContextTokens;
  final int? maxOutputTokens;
  final bool maxContextUnlocked;
  final String assistantPrefill;
  final String assistantImpersonation;
  final bool? functionCalling;
  final bool useSystemPrompt;
  final bool squashSystemMessages;
  final String reasoningEffort;
  final bool streamResponse;
  final List<String> warnings;
  final Map<String, dynamic> rawPreset;
  final Map<String, dynamic> compatibilityData;
  final List<TavernWorldBook> worldBooks;

  const SillyTavernPreset({
    required this.id,
    required this.name,
    required this.sourceFileName,
    required this.importedAt,
    required this.sourceFormat,
    required this.prompts,
    required this.promptOrderGroups,
    required this.selectedOrderIndex,
    required this.regexScriptCount,
    required this.regexScripts,
    required this.regexAuthorized,
    required this.parameterCompatibility,
    required this.temperature,
    required this.topP,
    required this.topK,
    required this.minP,
    required this.topA,
    required this.repetitionPenalty,
    required this.frequencyPenalty,
    required this.presencePenalty,
    required this.seed,
    required this.maxContextTokens,
    required this.maxOutputTokens,
    required this.maxContextUnlocked,
    required this.assistantPrefill,
    required this.assistantImpersonation,
    required this.functionCalling,
    required this.useSystemPrompt,
    required this.squashSystemMessages,
    required this.reasoningEffort,
    required this.streamResponse,
    required this.warnings,
    required this.rawPreset,
    this.compatibilityData = const {},
    this.worldBooks = const [],
  });

  SillyTavernPromptOrderGroup get selectedOrder =>
      promptOrderGroups[selectedOrderIndex];

  Map<String, SillyTavernPrompt> get promptsById => <String, SillyTavernPrompt>{
    for (final prompt in prompts) prompt.identifier: prompt,
  };

  Iterable<SillyTavernPrompt> get enabledPrompts sync* {
    final byId = promptsById;
    for (final entry in selectedOrder.entries) {
      if (!entry.enabled) continue;
      final prompt = byId[entry.identifier];
      if (prompt != null) yield prompt;
    }
  }

  int get enabledPromptCount => enabledPrompts.length;
  int get markerCount => enabledPrompts.where((prompt) => prompt.marker).length;
  int get absoluteInjectionCount =>
      enabledPrompts.where((prompt) => prompt.isAbsoluteInjection).length;
  int get attachmentCount =>
      enabledPrompts.where((prompt) => prompt.hasAttachment).length;

  int parameterStatusCount(
    SillyTavernParameterStatus status, {
    bool topLevelOnly = false,
  }) => parameterCompatibility.where((entry) {
    if (entry.status != status) return false;
    return !topLevelOnly || !entry.field.startsWith('extensions.');
  }).length;
}

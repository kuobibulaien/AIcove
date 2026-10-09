library;

import 'dart:math';

import '../../../core/utils/token_estimator.dart';
import '../../conversation_state/domain/mvu_content.dart';
import 'silly_tavern_macro_evaluator.dart';
import 'silly_tavern_preset.dart';
import 'silly_tavern_world_book.dart';

class SillyTavernAssemblyContext {
  final String characterName;
  final String userName;
  final String characterDescription;
  final String scenario;
  final String original;
  final String runtimeSystemContent;
  final List<Map<String, dynamic>> protectedRuntimeMessages;
  final Map<String, String> initialVariables;
  final List<String> initialWarnings;
  final List<TavernWorldInjection> worldInjections;

  /// MVU 楼层变量 `{'stat_data': …}`（ADR0071）；null 表示本请求 MVU 未生效。
  final Map<String, Object?>? messageVariables;

  const SillyTavernAssemblyContext({
    required this.characterName,
    required this.userName,
    required this.characterDescription,
    required this.scenario,
    this.original = '',
    this.runtimeSystemContent = '',
    this.protectedRuntimeMessages = const <Map<String, dynamic>>[],
    this.initialVariables = const <String, String>{},
    this.initialWarnings = const <String>[],
    this.worldInjections = const [],
    this.messageVariables,
  });
}

class SillyTavernAssemblyEntry {
  final Map<String, dynamic> message;
  final String source;
  final String label;
  final bool isHistory;
  final bool protectedFromTruncation;

  const SillyTavernAssemblyEntry({
    required this.message,
    required this.source,
    required this.label,
    required this.isHistory,
    required this.protectedFromTruncation,
  });

  Map<String, dynamic> toTraceJson(int order) => <String, dynamic>{
    'order': order,
    'source': source,
    'label': label,
    'role': (message['role'] ?? '').toString(),
    'content': message['content'],
    'isHistory': isHistory,
    'protectedFromTruncation': protectedFromTruncation,
  };
}

class SillyTavernAssemblyResult {
  final List<Map<String, dynamic>> messages;
  final List<SillyTavernAssemblyEntry> entries;
  final List<String> warnings;
  final int originalHistoryCount;
  final int keptHistoryCount;
  final bool historyIncluded;
  final Map<String, String> variables;
  final Set<String> appliedMacros;
  final Set<String> unknownMacros;

  const SillyTavernAssemblyResult({
    required this.messages,
    required this.entries,
    required this.warnings,
    required this.originalHistoryCount,
    required this.keptHistoryCount,
    required this.historyIncluded,
    required this.variables,
    required this.appliedMacros,
    required this.unknownMacros,
  });

  int get droppedHistoryCount => originalHistoryCount - keptHistoryCount;

  List<Map<String, dynamic>> get traceEntries => <Map<String, dynamic>>[
    for (var index = 0; index < entries.length; index++)
      entries[index].toTraceJson(index),
  ];
}

class _ResolvedInjection {
  final String role;
  final String content;
  final String promptId;
  final int depth;
  final int order;

  const _ResolvedInjection({
    required this.role,
    required this.content,
    required this.promptId,
    required this.depth,
    required this.order,
  });
}

class _ResolvedAttachment {
  final String promptRole;
  final String content;
  final String promptId;
  final String promptName;
  final int targetIndex;
  final String targetRole;
  final String side;

  const _ResolvedAttachment({
    required this.promptRole,
    required this.content,
    required this.promptId,
    required this.promptName,
    required this.targetIndex,
    required this.targetRole,
    required this.side,
  });
}

class _AttachmentTargetState {
  final int entryIndex;
  final List<_ResolvedAttachment> starts = <_ResolvedAttachment>[];
  final List<_ResolvedAttachment> ends = <_ResolvedAttachment>[];

  _AttachmentTargetState(this.entryIndex);

  Iterable<_ResolvedAttachment> get all sync* {
    yield* starts;
    yield* ends;
  }
}

/// 按 SillyTavern PromptManager / OpenAI prompt_order 语义组装消息。
class SillyTavernPresetAssembler {
  static const Set<String> _emptyDynamicMarkers = <String>{
    'dialogueExamples',
    'worldInfoBefore',
    'worldInfoAfter',
    'charPersonality',
    'personaDescription',
  };

  final SillyTavernMacroEvaluator _macroEvaluator;

  const SillyTavernPresetAssembler({
    SillyTavernMacroEvaluator macroEvaluator =
        const SillyTavernMacroEvaluator(),
  }) : _macroEvaluator = macroEvaluator;

  SillyTavernAssemblyResult assemble({
    required SillyTavernPreset preset,
    required List<Map<String, dynamic>> historyMessages,
    required SillyTavernAssemblyContext context,
    required int maxContextTokens,
    int reserveTokens = 2048,
    bool truncateHistory = true,
    SillyTavernRandomIndexPicker? randomIndexPicker,
  }) {
    final warnings = <String>[...preset.warnings, ...context.initialWarnings];
    final variables = Map<String, String>.from(context.initialVariables);
    final appliedMacros = <String>{};
    final unknownMacros = <String>{};
    final random = Random();
    final effectiveRandomIndexPicker = randomIndexPicker ?? random.nextInt;
    final lastUserMessage = _findLastUserMessage(historyMessages);
    final promptById = preset.promptsById;
    final orderedPrompts = <SillyTavernPrompt>[];
    for (final orderEntry in preset.selectedOrder.entries) {
      if (!orderEntry.enabled) continue;
      final prompt = promptById[orderEntry.identifier];
      if (prompt == null) continue;
      if (!_runsOnNormalTrigger(prompt)) {
        warnings.add('${prompt.identifier} 仅用于非 normal 触发，当前请求已跳过');
        continue;
      }
      orderedPrompts.add(prompt);
    }

    final injections = <_ResolvedInjection>[];
    final attachments = <_ResolvedAttachment>[];
    final renderedByPrompt = <String, String>{};
    for (final prompt in orderedPrompts) {
      if (prompt.identifier == 'chatHistory') continue;
      final content = _resolvePromptContent(
        prompt,
        context,
        warnings,
        variables: variables,
        appliedMacros: appliedMacros,
        unknownMacros: unknownMacros,
        randomIndexPicker: effectiveRandomIndexPicker,
        lastUserMessage: lastUserMessage,
      );
      renderedByPrompt[prompt.identifier] = content;
      if (prompt.hasAttachment && content.trim().isNotEmpty) {
        attachments.add(
          _ResolvedAttachment(
            promptRole: prompt.role,
            content: content.trim(),
            promptId: prompt.identifier,
            promptName: prompt.name,
            targetIndex: prompt.attachIndex!,
            targetRole: prompt.attachRole!,
            side: prompt.attachSide!,
          ),
        );
        continue;
      }
      if (!prompt.isAbsoluteInjection || content.trim().isEmpty) continue;
      injections.add(
        _ResolvedInjection(
          role: prompt.role,
          content: content.trim(),
          promptId: prompt.identifier,
          depth: prompt.injectionDepth,
          order: prompt.injectionOrder,
        ),
      );
    }

    for (final world in context.worldInjections.where((e) => e.position == 4)) {
      final result = _macroEvaluator.evaluate(
        world.content,
        promptId: 'world.${world.id}',
        values: _buildMacroValues(context, lastUserMessage),
        variables: variables,
        randomIndexPicker: effectiveRandomIndexPicker,
        warnings: warnings,
        messageVariables: context.messageVariables,
      );
      appliedMacros.addAll(result.appliedMacros);
      unknownMacros.addAll(result.unknownMacros);
      if (result.text.trim().isNotEmpty) {
        injections.add(
          _ResolvedInjection(
            role: world.role,
            content: result.text,
            promptId: 'world.${world.id}',
            depth: world.depth,
            order: world.order,
          ),
        );
      }
    }
    for (final position in const [0, 1]) {
      final marker = position == 0 ? 'worldInfoBefore' : 'worldInfoAfter';
      if (context.worldInjections.any((e) => e.position == position) &&
          !orderedPrompts.any((p) => p.identifier == marker)) {
        warnings.add('$marker 未启用或不存在，对应世界书内容未注入');
      }
    }

    final historyBlock = _buildHistoryBlock(
      historyMessages: historyMessages,
      injections: injections,
      runtimeSystemContent: context.runtimeSystemContent,
    );
    final assembled = <SillyTavernAssemblyEntry>[];
    var historyIncluded = false;
    var runtimeIncluded = false;
    for (final prompt in orderedPrompts) {
      if (prompt.identifier == 'chatHistory') {
        if (historyIncluded) {
          warnings.add('chatHistory 出现多次，仅使用第一个启用节点');
          continue;
        }
        historyIncluded = true;
        runtimeIncluded = context.runtimeSystemContent.trim().isNotEmpty;
        assembled.addAll(historyBlock);
        continue;
      }
      if (prompt.isAbsoluteInjection || prompt.hasAttachment) continue;
      final content =
          renderedByPrompt[prompt.identifier] ??
          _resolvePromptContent(
            prompt,
            context,
            warnings,
            variables: variables,
            appliedMacros: appliedMacros,
            unknownMacros: unknownMacros,
            randomIndexPicker: effectiveRandomIndexPicker,
            lastUserMessage: lastUserMessage,
          );
      if (content.trim().isEmpty) continue;
      assembled.add(
        SillyTavernAssemblyEntry(
          message: <String, dynamic>{
            'role': prompt.role,
            'content': content.trim(),
          },
          source: 'preset.${prompt.identifier}',
          label: prompt.name,
          isHistory: false,
          protectedFromTruncation: true,
        ),
      );
    }

    _applyAttachments(assembled, attachments, warnings);

    if (!runtimeIncluded && context.runtimeSystemContent.trim().isNotEmpty) {
      assembled.add(
        SillyTavernAssemblyEntry(
          message: <String, dynamic>{
            'role': 'system',
            'content': context.runtimeSystemContent.trim(),
          },
          source: 'runtime.system',
          label: 'AIcove 运行时规则',
          isHistory: false,
          protectedFromTruncation: true,
        ),
      );
    }
    for (
      var index = 0;
      index < context.protectedRuntimeMessages.length;
      index++
    ) {
      assembled.add(
        SillyTavernAssemblyEntry(
          message: Map<String, dynamic>.from(
            context.protectedRuntimeMessages[index],
          ),
          source: 'runtime.message.$index',
          label: 'AIcove 运行时消息',
          isHistory: false,
          protectedFromTruncation: true,
        ),
      );
    }

    var messagesBeforePrefill = preset.squashSystemMessages
        ? _squashConsecutiveSystemEntries(assembled)
        : assembled;
    final prefillResult = _macroEvaluator.evaluate(
      preset.assistantPrefill,
      promptId: 'assistant_prefill',
      values: _buildMacroValues(context, lastUserMessage),
      variables: variables,
      randomIndexPicker: effectiveRandomIndexPicker,
      warnings: warnings,
      messageVariables: context.messageVariables,
    );
    appliedMacros.addAll(prefillResult.appliedMacros);
    unknownMacros.addAll(prefillResult.unknownMacros);
    final assistantPrefill = prefillResult.text.trimRight();
    if (assistantPrefill.isNotEmpty) {
      messagesBeforePrefill = _appendAssistantPrefill(
        messagesBeforePrefill,
        assistantPrefill,
      );
    }

    final trimmed = !truncateHistory
        ? messagesBeforePrefill
        : _truncatePreservingOrder(
            messagesBeforePrefill,
            maxContextTokens: maxContextTokens,
            reserveTokens: reserveTokens,
            warnings: warnings,
          );
    final keptHistoryCount = trimmed.where((entry) => entry.isHistory).length;
    return SillyTavernAssemblyResult(
      messages: List.unmodifiable(
        trimmed
            .map((entry) => Map<String, dynamic>.from(entry.message))
            .toList(),
      ),
      entries: List.unmodifiable(trimmed),
      warnings: List.unmodifiable(_deduplicate(warnings)),
      originalHistoryCount: historyMessages.length,
      keptHistoryCount: keptHistoryCount,
      historyIncluded: historyIncluded,
      variables: Map.unmodifiable(variables),
      appliedMacros: Set.unmodifiable(appliedMacros),
      unknownMacros: Set.unmodifiable(unknownMacros),
    );
  }

  List<SillyTavernAssemblyEntry> _buildHistoryBlock({
    required List<Map<String, dynamic>> historyMessages,
    required List<_ResolvedInjection> injections,
    required String runtimeSystemContent,
  }) {
    final entries = <SillyTavernAssemblyEntry>[];
    if (runtimeSystemContent.trim().isNotEmpty) {
      entries.add(
        SillyTavernAssemblyEntry(
          message: <String, dynamic>{
            'role': 'system',
            'content': runtimeSystemContent.trim(),
          },
          source: 'runtime.system',
          label: 'AIcove 运行时规则',
          isHistory: false,
          protectedFromTruncation: true,
        ),
      );
    }

    final injectionsByPosition = <int, List<_ResolvedInjection>>{};
    for (final injection in injections) {
      final position = (historyMessages.length - injection.depth).clamp(
        0,
        historyMessages.length,
      );
      injectionsByPosition.putIfAbsent(position, () => []).add(injection);
    }
    for (var position = 0; position <= historyMessages.length; position++) {
      final atPosition = injectionsByPosition[position];
      if (atPosition != null) {
        // 酒馆先在“最新消息优先”的数组中按 order 降序、role
        // system/user/assistant 插入，随后整体 reverse。这里直接输出最终时间序，
        // 因而等价顺序为 order 升序、role assistant/user/system。
        final orders = atPosition.map((item) => item.order).toSet().toList()
          ..sort();
        for (final order in orders) {
          for (final role in const <String>['assistant', 'user', 'system']) {
            final rolePrompts = atPosition
                .where((item) => item.order == order && item.role == role)
                .toList();
            if (rolePrompts.isEmpty) continue;
            entries.add(
              SillyTavernAssemblyEntry(
                message: <String, dynamic>{
                  'role': role,
                  'content': rolePrompts.map((item) => item.content).join('\n'),
                },
                source:
                    'preset.injection.${rolePrompts.map((item) => item.promptId).join('+')}',
                label: '酒馆深度注入 depth=${rolePrompts.first.depth} order=$order',
                isHistory: false,
                protectedFromTruncation: true,
              ),
            );
          }
        }
      }
      if (position >= historyMessages.length) continue;
      entries.add(
        SillyTavernAssemblyEntry(
          message: Map<String, dynamic>.from(historyMessages[position]),
          source: 'history.$position',
          label: '数据库原始消息',
          isHistory: true,
          protectedFromTruncation: false,
        ),
      );
    }
    return entries;
  }

  String _resolvePromptContent(
    SillyTavernPrompt prompt,
    SillyTavernAssemblyContext context,
    List<String> warnings, {
    required Map<String, String> variables,
    required Set<String> appliedMacros,
    required Set<String> unknownMacros,
    required SillyTavernRandomIndexPicker randomIndexPicker,
    required String lastUserMessage,
  }) {
    String content;
    switch (prompt.identifier) {
      case 'charDescription':
        content = context.characterDescription;
      case 'scenario':
        content = context.scenario;
      case 'worldInfoBefore':
      case 'worldInfoAfter':
        final position = prompt.identifier == 'worldInfoBefore' ? 0 : 1;
        content = context.worldInjections
            .where((e) => e.position == position)
            .map((e) => e.content)
            .join('\n');
      default:
        if (prompt.marker && _emptyDynamicMarkers.contains(prompt.identifier)) {
          content = '';
        } else {
          content = prompt.content;
        }
    }
    if (containsEjs(content)) {
      warnings.add('${prompt.name} 含 EJS 模板（<% %>），本期不支持，已跳过该条目');
      return '';
    }
    if (context.messageVariables == null && isMvuSpecificContent(content)) {
      warnings.add('${prompt.name} 属于 MVU 变量，本角色未启用 MVU，已跳过');
      return '';
    }
    final values = _buildMacroValues(context, lastUserMessage);
    final result = _macroEvaluator.evaluate(
      content,
      promptId: prompt.identifier,
      values: values,
      variables: variables,
      randomIndexPicker: randomIndexPicker,
      warnings: warnings,
      messageVariables: context.messageVariables,
    );
    appliedMacros.addAll(result.appliedMacros);
    unknownMacros.addAll(result.unknownMacros);
    return result.text;
  }

  Map<String, String> _buildMacroValues(
    SillyTavernAssemblyContext context,
    String lastUserMessage,
  ) => <String, String>{
    'char': context.characterName,
    'user': context.userName,
    'description': context.characterDescription,
    'chardescription': context.characterDescription,
    'scenario': context.scenario,
    'lastusermessage': lastUserMessage,
    if (context.original.isNotEmpty) 'original': context.original,
  };

  void _applyAttachments(
    List<SillyTavernAssemblyEntry> entries,
    List<_ResolvedAttachment> attachments,
    List<String> warnings,
  ) {
    final targets = <int, _AttachmentTargetState>{};
    for (final attachment in attachments) {
      final entryIndex = _findAttachmentTarget(
        entries,
        role: attachment.targetRole,
        oneBasedIndexFromEnd: attachment.targetIndex,
      );
      if (entryIndex < 0) {
        warnings.add(
          '${attachment.promptId} 找不到第 ${attachment.targetIndex} 个倒序 '
          '${attachment.targetRole} 消息，已按普通相对节点追加',
        );
        entries.add(
          SillyTavernAssemblyEntry(
            message: <String, dynamic>{
              'role': attachment.promptRole,
              'content': attachment.content,
            },
            source: 'preset.${attachment.promptId}.attachFallback',
            label: attachment.promptName,
            isHistory: false,
            protectedFromTruncation: true,
          ),
        );
        continue;
      }
      final state = targets.putIfAbsent(
        entryIndex,
        () => _AttachmentTargetState(entryIndex),
      );
      if (attachment.side == 'start') {
        state.starts.add(attachment);
      } else {
        state.ends.add(attachment);
      }
    }

    for (final state in targets.values) {
      final original = entries[state.entryIndex];
      final message = Map<String, dynamic>.from(original.message);
      message['content'] = _mergeAttachedContent(
        message['content'],
        starts: state.starts.map((item) => item.content).toList(),
        ends: state.ends.map((item) => item.content).toList(),
      );
      entries[state.entryIndex] = SillyTavernAssemblyEntry(
        message: message,
        source:
            '${original.source}+attach.${state.all.map((item) => item.promptId).join('+')}',
        label: '${original.label} + 酒馆附着节点',
        isHistory: original.isHistory,
        protectedFromTruncation: original.protectedFromTruncation,
      );
    }
  }

  int _findAttachmentTarget(
    List<SillyTavernAssemblyEntry> entries, {
    required String role,
    required int oneBasedIndexFromEnd,
  }) {
    var seen = 0;
    for (var index = entries.length - 1; index >= 0; index--) {
      if (entries[index].message['role'] != role) continue;
      seen++;
      if (seen == oneBasedIndexFromEnd) return index;
    }
    return -1;
  }

  dynamic _mergeAttachedContent(
    dynamic original, {
    required List<String> starts,
    required List<String> ends,
  }) {
    if (original is List) {
      final parts = original
          .map(
            (part) => part is Map
                ? Map<String, dynamic>.from(part)
                : <String, dynamic>{'type': 'text', 'text': part.toString()},
          )
          .toList(growable: true);
      if (starts.isNotEmpty) {
        parts.insert(0, <String, dynamic>{
          'type': 'text',
          'text': starts.join('\n\n'),
        });
      }
      if (ends.isNotEmpty) {
        parts.add(<String, dynamic>{'type': 'text', 'text': ends.join('\n\n')});
      }
      return parts;
    }
    return <String>[
      ...starts,
      if (original?.toString().isNotEmpty == true) original.toString(),
      ...ends,
    ].join('\n\n');
  }

  List<SillyTavernAssemblyEntry> _squashConsecutiveSystemEntries(
    List<SillyTavernAssemblyEntry> source,
  ) {
    final squashed = <SillyTavernAssemblyEntry>[];
    for (final entry in source) {
      final isSystem = entry.message['role'] == 'system';
      final hasName = entry.message['name']?.toString().isNotEmpty == true;
      final canMerge = isSystem && !hasName;
      if (canMerge && squashed.isNotEmpty) {
        final previous = squashed.last;
        final previousCanMerge =
            previous.message['role'] == 'system' &&
            previous.message['name']?.toString().isNotEmpty != true;
        if (previousCanMerge) {
          final mergedMessage = Map<String, dynamic>.from(previous.message);
          mergedMessage['content'] = <String>[
            previous.message['content']?.toString() ?? '',
            entry.message['content']?.toString() ?? '',
          ].where((value) => value.isNotEmpty).join('\n');
          squashed[squashed.length - 1] = SillyTavernAssemblyEntry(
            message: mergedMessage,
            source: '${previous.source}+${entry.source}',
            label: '${previous.label} + ${entry.label}',
            isHistory: previous.isHistory && entry.isHistory,
            protectedFromTruncation:
                previous.protectedFromTruncation ||
                entry.protectedFromTruncation,
          );
          continue;
        }
      }
      squashed.add(entry);
    }
    return squashed;
  }

  List<SillyTavernAssemblyEntry> _appendAssistantPrefill(
    List<SillyTavernAssemblyEntry> source,
    String prefill,
  ) {
    final result = List<SillyTavernAssemblyEntry>.of(source);
    if (result.isNotEmpty && result.last.message['role'] == 'assistant') {
      final previous = result.last;
      final message = Map<String, dynamic>.from(previous.message);
      final content = message['content'];
      if (content is String) {
        message['content'] = <String>[
          content,
          prefill,
        ].where((value) => value.isNotEmpty).join('\n\n');
        result[result.length - 1] = SillyTavernAssemblyEntry(
          message: message,
          source: '${previous.source}+preset.assistantPrefill',
          label: '${previous.label} + Assistant Prefill',
          isHistory: previous.isHistory,
          protectedFromTruncation: true,
        );
        return result;
      }
    }
    result.add(
      SillyTavernAssemblyEntry(
        message: <String, dynamic>{'role': 'assistant', 'content': prefill},
        source: 'preset.assistantPrefill',
        label: 'Assistant Prefill',
        isHistory: false,
        protectedFromTruncation: true,
      ),
    );
    return result;
  }

  String _findLastUserMessage(List<Map<String, dynamic>> historyMessages) {
    for (final message in historyMessages.reversed) {
      if (message['role'] != 'user') continue;
      final content = message['content'];
      if (content is String) return content;
      if (content is List) {
        final textParts = <String>[];
        for (final part in content) {
          if (part is Map && part['type'] == 'text') {
            final text = part['text']?.toString() ?? '';
            if (text.isNotEmpty) textParts.add(text);
          }
        }
        if (textParts.isNotEmpty) return textParts.join('\n');
      }
    }
    return '';
  }

  bool _runsOnNormalTrigger(SillyTavernPrompt prompt) {
    if (prompt.injectionTriggers.isEmpty) return true;
    return prompt.injectionTriggers
        .map((trigger) => trigger.toLowerCase())
        .contains('normal');
  }

  List<SillyTavernAssemblyEntry> _truncatePreservingOrder(
    List<SillyTavernAssemblyEntry> source, {
    required int maxContextTokens,
    required int reserveTokens,
    required List<String> warnings,
  }) {
    final availableTokens = maxContextTokens - reserveTokens;
    if (source.isEmpty || availableTokens <= 0) return List.of(source);
    final kept = List<SillyTavernAssemblyEntry>.of(source);
    var usedTokens = _estimateEntries(kept);
    SillyTavernAssemblyEntry? latestUser;
    for (final entry in kept.reversed) {
      if (entry.isHistory && entry.message['role'] == 'user') {
        latestUser = entry;
        break;
      }
    }
    var droppedCount = 0;
    while (usedTokens > availableTokens) {
      final removableIndex = kept.indexWhere(
        (entry) =>
            entry.isHistory &&
            !entry.protectedFromTruncation &&
            !identical(entry, latestUser),
      );
      if (removableIndex < 0) break;
      usedTokens -= estimateMessageTokens(kept[removableIndex].message);
      kept.removeAt(removableIndex);
      droppedCount++;
    }
    final withoutOrphanTools = _dropOrphanToolEntries(kept);
    droppedCount += kept.length - withoutOrphanTools.length;
    if (droppedCount > 0) {
      warnings.add('上下文超出预算，已按原顺序移除 $droppedCount 条最旧历史消息');
    }
    if (_estimateEntries(withoutOrphanTools) > availableTokens) {
      warnings.add('预设与最新用户消息已超过上下文预算，仍保留关键节点交给供应商处理');
    }
    return withoutOrphanTools;
  }

  List<SillyTavernAssemblyEntry> _dropOrphanToolEntries(
    List<SillyTavernAssemblyEntry> entries,
  ) {
    final kept = <SillyTavernAssemblyEntry>[];
    for (final entry in entries) {
      final role = (entry.message['role'] ?? '').toString();
      if (role != 'tool' && role != 'function') {
        kept.add(entry);
        continue;
      }
      if (_hasMatchingAssistantToolCall(kept, entry.message)) kept.add(entry);
    }
    return kept;
  }

  bool _hasMatchingAssistantToolCall(
    List<SillyTavernAssemblyEntry> previous,
    Map<String, dynamic> toolMessage,
  ) {
    final toolCallId = (toolMessage['tool_call_id'] ?? '').toString().trim();
    final toolName = (toolMessage['name'] ?? '').toString().trim();
    for (var index = previous.length - 1; index >= 0; index--) {
      final candidate = previous[index].message;
      if (candidate['role'] != 'assistant') continue;
      final toolCalls = candidate['tool_calls'];
      if (toolCalls is List && toolCalls.isNotEmpty) {
        if (toolCallId.isEmpty) return true;
        for (final call in toolCalls) {
          if (call is Map && call['id']?.toString() == toolCallId) return true;
        }
      }
      final functionCall = candidate['function_call'];
      if (functionCall is Map) {
        if (toolName.isEmpty || functionCall['name']?.toString() == toolName) {
          return true;
        }
      }
    }
    return false;
  }

  int _estimateEntries(List<SillyTavernAssemblyEntry> entries) => entries.fold(
    0,
    (sum, entry) => sum + estimateMessageTokens(entry.message),
  );

  List<String> _deduplicate(List<String> values) {
    final seen = <String>{};
    return values.where(seen.add).toList(growable: false);
  }
}

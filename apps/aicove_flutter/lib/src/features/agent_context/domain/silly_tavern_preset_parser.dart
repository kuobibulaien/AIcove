library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'silly_tavern_preset.dart';
import 'silly_tavern_world_book.dart';

class SillyTavernPresetParseException implements Exception {
  final String message;

  const SillyTavernPresetParseException(this.message);

  @override
  String toString() => message;
}

/// SillyTavern Chat Completion 预设唯一 JSON 解析入口。
class SillyTavernPresetParser {
  static const int maxSourceBytes = 2 * 1024 * 1024;
  static const int maxPromptCount = 1000;
  static const int maxOrderGroupCount = 100;
  static const int maxOrderEntryCount = 2000;

  const SillyTavernPresetParser();

  SillyTavernPreset parseSource(
    String source, {
    required String sourceFileName,
    String? storedId,
    String? storedName,
    DateTime? importedAt,
    bool regexAuthorized = false,
  }) {
    if (utf8.encode(source).length > maxSourceBytes) {
      throw const SillyTavernPresetParseException('预设文件超过 2 MB，已拒绝导入');
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const SillyTavernPresetParseException('文件不是有效的 JSON');
    }
    if (decoded is! Map) {
      throw const SillyTavernPresetParseException('预设 JSON 顶层必须是对象');
    }
    return parseMap(
      Map<String, dynamic>.from(decoded),
      sourceFileName: sourceFileName,
      storedId: storedId,
      storedName: storedName,
      importedAt: importedAt,
      regexAuthorized: regexAuthorized,
    );
  }

  SillyTavernPreset parseMap(
    Map<String, dynamic> raw, {
    required String sourceFileName,
    String? storedId,
    String? storedName,
    DateTime? importedAt,
    bool regexAuthorized = false,
    Map<String, dynamic> compatibilityData = const {},
  }) {
    final warnings = <String>[];
    final wrappedData = raw['data'];
    final isPromptManagerWrapper = raw['type'] != null && wrappedData is Map;
    final body = isPromptManagerWrapper
        ? Map<String, dynamic>.from(wrappedData)
        : raw;
    final sourceFormat = isPromptManagerWrapper
        ? 'prompt_manager_export'
        : 'chat_completion_preset';

    final rawPrompts = body['prompts'];
    if (rawPrompts is! List ||
        (rawPrompts.isEmpty && !isPromptManagerWrapper)) {
      throw const SillyTavernPresetParseException(
        '未找到 prompts；请选择酒馆的 Chat Completion / OpenAI 预设 JSON',
      );
    }
    if (rawPrompts.length > maxPromptCount) {
      throw const SillyTavernPresetParseException('prompts 数量超过安全上限 1000');
    }

    final prompts = <SillyTavernPrompt>[];
    final promptIds = <String>{};
    for (var index = 0; index < rawPrompts.length; index++) {
      final rawPrompt = rawPrompts[index];
      if (rawPrompt is! Map) {
        warnings.add('已忽略第 ${index + 1} 个非对象 prompt');
        continue;
      }
      final prompt = Map<String, dynamic>.from(rawPrompt);
      final identifier = _string(prompt['identifier']);
      if (identifier.isEmpty) {
        warnings.add('已忽略第 ${index + 1} 个缺少 identifier 的 prompt');
        continue;
      }
      final isDuplicate = !promptIds.add(identifier);
      final role = _normalizeRole(prompt['role'], warnings, identifier);
      final attachment = _parseAttachment(prompt, warnings, identifier);
      final parsedPrompt = SillyTavernPrompt(
        identifier: identifier,
        name: _string(prompt['name']).isEmpty
            ? identifier
            : _string(prompt['name']),
        role: role,
        content: prompt['content'] is String ? prompt['content'] as String : '',
        marker: prompt['marker'] == true,
        systemPrompt: prompt['system_prompt'] == true,
        injectionPosition: _int(prompt['injection_position'], fallback: 0),
        injectionDepth: _int(
          prompt['injection_depth'],
          fallback: 4,
        ).clamp(0, 1000),
        injectionOrder: _int(prompt['injection_order'], fallback: 100),
        injectionTriggers: _stringList(prompt['injection_trigger']),
        attachIndex: attachment.index,
        attachRole: attachment.role,
        attachSide: attachment.side,
      );
      if (isDuplicate) {
        final existingIndex = prompts.indexWhere(
          (item) => item.identifier == identifier,
        );
        prompts[existingIndex] = parsedPrompt;
        warnings.add('prompt identifier 重复，已保留后一个：$identifier');
      } else {
        prompts.add(parsedPrompt);
      }
    }
    final promptOverrides =
        compatibilityData['promptEnabled'] as Map? ?? const {};
    final groups = _parseOrderGroups(body['prompt_order'], warnings)
        .map(
          (group) => SillyTavernPromptOrderGroup(
            sourceIndex: group.sourceIndex,
            characterId: group.characterId,
            entries: group.entries
                .map(
                  (entry) => SillyTavernPromptOrderEntry(
                    identifier: entry.identifier,
                    enabled:
                        promptOverrides[entry.identifier] as bool? ??
                        entry.enabled,
                  ),
                )
                .toList(),
          ),
        )
        .toList();
    if (groups.isEmpty) {
      throw const SillyTavernPresetParseException(
        '未找到有效的 prompt_order；该文件不能按酒馆顺序运行',
      );
    }
    if (isPromptManagerWrapper) {
      final missingIds = <String>{
        for (final group in groups)
          for (final entry in group.entries)
            if (!promptIds.contains(entry.identifier)) entry.identifier,
      };
      for (final identifier in missingIds) {
        promptIds.add(identifier);
        prompts.add(_buildPromptManagerPlaceholder(identifier));
      }
      if (missingIds.isNotEmpty) {
        warnings.add(
          'Prompt Manager 导出不携带酒馆内置 prompt 正文；已补齐 ${missingIds.length} 个顺序占位，动态 marker 可正常注入，空正文节点会跳过',
        );
      }
    }
    if (prompts.isEmpty) {
      throw const SillyTavernPresetParseException('没有可用的 prompt');
    }
    final selectedOrderIndex = _selectOrderGroup(groups, promptIds);
    final selected = groups[selectedOrderIndex];
    final unknownOrderIds = selected.entries
        .where((entry) => !promptIds.contains(entry.identifier))
        .map((entry) => entry.identifier)
        .toSet();
    if (unknownOrderIds.isNotEmpty) {
      warnings.add('prompt_order 中有 ${unknownOrderIds.length} 个未知节点，运行时会跳过');
    }

    final regexScripts = _parseRegexScripts(
      raw,
      body,
      warnings,
      compatibilityData: compatibilityData,
    );
    final worldBooks = <TavernWorldBook>[];
    for (final saved in compatibilityData['worldBooks'] as List? ?? const []) {
      if (saved is! Map || saved['source'] is! Map) {
        throw const SillyTavernPresetParseException('世界书配置损坏');
      }
      final book = TavernWorldBook.parse(
        Map<String, dynamic>.from(saved['source'] as Map),
        saved['fileName']?.toString() ?? '世界书',
        storedId: saved['id']?.toString(),
        enabled: saved['enabled'] != false,
        overrides: saved['entryEnabled'] as Map? ?? const {},
      );
      worldBooks.add(book);
      warnings.addAll(book.warnings);
    }
    final regexScriptCount = regexScripts.length;
    if (regexScriptCount > 0) {
      warnings.add(
        regexAuthorized
            ? '检测到 $regexScriptCount 条 regex：已授权在请求与显示副本上运行'
            : '检测到 $regexScriptCount 条 regex：尚未授权，不会改写请求或显示内容',
      );
    }
    final parameterCompatibility = _classifyTopLevelParameters(body);
    final maxContextTokens = _nullableInt(body['openai_max_context'], min: 1);
    if (body.containsKey('openai_max_context') && maxContextTokens == null) {
      warnings.add('openai_max_context 非法，已回退模型上下文预算');
    }
    final maxOutputTokens = _nullableInt(body['openai_max_tokens'], min: 1);
    if (body.containsKey('openai_max_tokens') && maxOutputTokens == null) {
      warnings.add('openai_max_tokens 非法，已回退模型输出预算');
    }

    final canonicalSource = jsonEncode(raw);
    final digest = sha256.convert(utf8.encode(canonicalSource)).toString();
    final fileBaseName = sourceFileName
        .replaceFirst(RegExp(r'\.[^.]+$'), '')
        .trim();
    final declaredName = _string(body['name']);
    final name = (storedName?.trim().isNotEmpty ?? false)
        ? storedName!.trim()
        : declaredName.isNotEmpty
        ? declaredName
        : fileBaseName.isNotEmpty
        ? fileBaseName
        : 'SillyTavern 预设';

    return SillyTavernPreset(
      id: storedId?.trim().isNotEmpty == true
          ? storedId!.trim()
          : 'st_preset_${digest.substring(0, 24)}',
      name: name,
      sourceFileName: sourceFileName,
      importedAt: importedAt ?? DateTime.now(),
      sourceFormat: sourceFormat,
      prompts: List.unmodifiable(prompts),
      promptOrderGroups: List.unmodifiable(groups),
      selectedOrderIndex: selectedOrderIndex,
      regexScriptCount: regexScriptCount,
      regexScripts: List.unmodifiable(regexScripts),
      regexAuthorized: regexAuthorized,
      parameterCompatibility: List.unmodifiable(parameterCompatibility),
      temperature: _boundedDouble(body['temperature'], min: 0, max: 2),
      topP: _boundedDouble(body['top_p'], min: 0, max: 1),
      topK: _nullableInt(body['top_k'], min: 0),
      minP: _boundedDouble(body['min_p'], min: 0, max: 1),
      topA: _boundedDouble(body['top_a'], min: 0, max: 1),
      repetitionPenalty: _finiteDouble(body['repetition_penalty']),
      frequencyPenalty: _finiteDouble(body['frequency_penalty']),
      presencePenalty: _finiteDouble(body['presence_penalty']),
      seed: _nullableInt(body['seed']),
      maxContextTokens: maxContextTokens,
      maxOutputTokens: maxOutputTokens,
      maxContextUnlocked: body['max_context_unlocked'] == true,
      assistantPrefill: _stringPreservingWhitespace(body['assistant_prefill']),
      assistantImpersonation: _stringPreservingWhitespace(
        body['assistant_impersonation'],
      ),
      functionCalling: body['function_calling'] is bool
          ? body['function_calling'] as bool
          : null,
      useSystemPrompt: body['use_sysprompt'] != false,
      squashSystemMessages: body['squash_system_messages'] == true,
      reasoningEffort: _string(body['reasoning_effort']),
      streamResponse: body['stream_openai'] == true,
      warnings: List.unmodifiable(warnings),
      rawPreset: Map.unmodifiable(raw),
      compatibilityData: Map.unmodifiable(compatibilityData),
      worldBooks: List.unmodifiable(worldBooks),
    );
  }

  List<SillyTavernPromptOrderGroup> _parseOrderGroups(
    dynamic rawOrder,
    List<String> warnings,
  ) {
    if (rawOrder is! List || rawOrder.isEmpty) return const [];
    if (rawOrder.length > maxOrderGroupCount) {
      throw const SillyTavernPresetParseException(
        'prompt_order 分组数量超过安全上限 100',
      );
    }

    final looksLikeDirectOrder = rawOrder.every(
      (item) => item is Map && item.containsKey('identifier'),
    );
    final rawGroups = looksLikeDirectOrder
        ? <dynamic>[
            <String, dynamic>{'order': rawOrder},
          ]
        : rawOrder;
    final groups = <SillyTavernPromptOrderGroup>[];
    var totalEntries = 0;
    for (var groupIndex = 0; groupIndex < rawGroups.length; groupIndex++) {
      final rawGroup = rawGroups[groupIndex];
      if (rawGroup is! Map) continue;
      final group = Map<String, dynamic>.from(rawGroup);
      final rawEntries = group['order'];
      if (rawEntries is! List || rawEntries.isEmpty) continue;
      final entries = <SillyTavernPromptOrderEntry>[];
      for (final rawEntry in rawEntries) {
        if (rawEntry is! Map) continue;
        final entry = Map<String, dynamic>.from(rawEntry);
        final identifier = _string(entry['identifier']);
        if (identifier.isEmpty) continue;
        entries.add(
          SillyTavernPromptOrderEntry(
            identifier: identifier,
            enabled: entry['enabled'] != false,
          ),
        );
      }
      totalEntries += entries.length;
      if (totalEntries > maxOrderEntryCount) {
        throw const SillyTavernPresetParseException(
          'prompt_order 节点数量超过安全上限 2000',
        );
      }
      if (entries.isEmpty) continue;
      groups.add(
        SillyTavernPromptOrderGroup(
          sourceIndex: groupIndex,
          characterId: _nullableString(
            group['character_id'] ?? group['characterId'],
          ),
          entries: List.unmodifiable(entries),
        ),
      );
    }
    if (groups.length < rawGroups.length) {
      warnings.add('已忽略空白或格式无效的 prompt_order 分组');
    }
    return groups;
  }

  int _selectOrderGroup(
    List<SillyTavernPromptOrderGroup> groups,
    Set<String> promptIds,
  ) {
    var selectedIndex = 0;
    var bestRecognizedCount = -1;
    var bestTotalCount = -1;
    for (var index = 0; index < groups.length; index++) {
      final group = groups[index];
      final recognized = group.entries
          .where((entry) => promptIds.contains(entry.identifier))
          .length;
      if (recognized > bestRecognizedCount ||
          (recognized == bestRecognizedCount &&
              group.entries.length > bestTotalCount)) {
        selectedIndex = index;
        bestRecognizedCount = recognized;
        bestTotalCount = group.entries.length;
      }
    }
    if (bestRecognizedCount <= 0) {
      throw const SillyTavernPresetParseException(
        'prompt_order 没有引用任何已定义 prompt',
      );
    }
    return selectedIndex;
  }

  List<SillyTavernRegexScript> _parseRegexScripts(
    Map<String, dynamic> root,
    Map<String, dynamic> body,
    List<String> warnings, {
    Map<String, dynamic> compatibilityData = const {},
  }) {
    final overrides = compatibilityData['regexEnabled'] as Map? ?? const {};
    final byId = <String, SillyTavernRegexScript>{};
    var invalidCount = 0;
    var duplicateCount = 0;
    var generatedIdCount = 0;

    void add(dynamic value, String source) {
      if (value is! List) return;
      for (final rawScript in value) {
        if (rawScript is! Map) {
          invalidCount++;
          continue;
        }
        final script = Map<String, dynamic>.from(rawScript);
        var id = _string(script['id']);
        final findRegex = _stringPreservingWhitespace(script['findRegex']);
        if (findRegex.isEmpty) {
          invalidCount++;
          continue;
        }
        if (id.isEmpty) {
          final digest = sha256.convert(utf8.encode(jsonEncode(script)));
          id = 'regex_${digest.toString().substring(0, 24)}';
          generatedIdCount++;
        }
        if (byId.containsKey(id)) {
          duplicateCount++;
          continue;
        }
        final placements = <int>[];
        final rawPlacements = script['placement'];
        if (rawPlacements is List) {
          for (final placement in rawPlacements) {
            final value = _nullableInt(placement);
            if (value != null) placements.add(value);
          }
        }
        byId[id] = SillyTavernRegexScript(
          id: id,
          name: _string(script['scriptName']).isEmpty
              ? id
              : _string(script['scriptName']),
          source: source,
          disabled: overrides[id] is bool
              ? !(overrides[id] as bool)
              : script['disabled'] == true,
          runOnEdit: script['runOnEdit'] == true,
          findRegex: findRegex,
          replaceString: _stringPreservingWhitespace(script['replaceString']),
          trimStrings: _stringListPreservingWhitespace(script['trimStrings']),
          placements: List.unmodifiable(placements),
          substituteRegex: _int(script['substituteRegex'], fallback: 0),
          minDepth: _nullableInt(script['minDepth'], min: -1),
          maxDepth: _nullableInt(script['maxDepth'], min: 0),
          markdownOnly: script['markdownOnly'] == true,
          promptOnly: script['promptOnly'] == true,
        );
      }
    }

    add(root['regex_scripts'], 'root.regex_scripts');
    final rootExtensions = root['extensions'];
    if (rootExtensions is Map) {
      add(rootExtensions['regex_scripts'], 'extensions.regex_scripts');
      _addSPresetRegexScripts(rootExtensions, add);
    }
    if (!identical(root, body)) {
      add(body['regex_scripts'], 'data.regex_scripts');
      final bodyExtensions = body['extensions'];
      if (bodyExtensions is Map) {
        add(bodyExtensions['regex_scripts'], 'data.extensions.regex_scripts');
        _addSPresetRegexScripts(bodyExtensions, add);
      }
    }
    add(compatibilityData['importedRegex'], 'plugin.importedRegex');
    if (byId.length > 1000) {
      throw const SillyTavernPresetParseException('正则规则超过安全上限 1000');
    }
    if (duplicateCount > 0) {
      warnings.add('已按 id 去重 $duplicateCount 条重复 regex，保留先出现的声明');
    }
    if (invalidCount > 0) {
      warnings.add('已忽略 $invalidCount 条缺少 findRegex 的无效 regex');
    }
    if (generatedIdCount > 0) {
      warnings.add('已为 $generatedIdCount 条缺少 id 的 regex 生成稳定标识');
    }
    return byId.values.toList(growable: false);
  }

  void _addSPresetRegexScripts(
    Map extensions,
    void Function(dynamic value, String source) add,
  ) {
    final sPreset = extensions['SPreset'];
    if (sPreset is! Map) return;
    final binding = sPreset['RegexBinding'];
    if (binding is! Map) return;
    add(binding['regexes'], 'extensions.SPreset.RegexBinding.regexes');
  }

  SillyTavernPrompt _buildPromptManagerPlaceholder(String identifier) {
    const dynamicMarkers = <String>{
      'worldInfoBefore',
      'worldInfoAfter',
      'charDescription',
      'charPersonality',
      'scenario',
      'personaDescription',
      'dialogueExamples',
      'chatHistory',
    };
    return SillyTavernPrompt(
      identifier: identifier,
      name: identifier,
      role: 'system',
      content: '',
      marker: dynamicMarkers.contains(identifier),
      systemPrompt: true,
      injectionPosition: 0,
      injectionDepth: 4,
      injectionOrder: 100,
      injectionTriggers: const <String>[],
      attachIndex: null,
      attachRole: null,
      attachSide: null,
    );
  }

  ({int? index, String? role, String? side}) _parseAttachment(
    Map<String, dynamic> prompt,
    List<String> warnings,
    String identifier,
  ) {
    final hasAny =
        prompt.containsKey('attach_index') ||
        prompt.containsKey('attach_role') ||
        prompt.containsKey('attach_side');
    if (!hasAny) return (index: null, role: null, side: null);

    final index = _nullableInt(prompt['attach_index'], min: 1);
    final rawRole = _string(prompt['attach_role']).toLowerCase();
    final role = const <String>{'system', 'user', 'assistant'}.contains(rawRole)
        ? rawRole
        : null;
    final rawSide = _string(prompt['attach_side']).toLowerCase();
    final side = const <String>{'start', 'end'}.contains(rawSide)
        ? rawSide
        : null;
    if (index == null || role == null || side == null) {
      warnings.add('$identifier 的 attach_* 字段不完整或无效，已按普通相对节点处理');
      return (index: null, role: null, side: null);
    }
    return (index: index, role: role, side: side);
  }

  List<SillyTavernParameterCompatibility> _classifyTopLevelParameters(
    Map<String, dynamic> body,
  ) {
    const applied = <String, String>{
      'assistant_prefill': '已映射为末尾 assistant prefill',
      'extensions': '已解析 regex 与受控扩展声明',
      'frequency_penalty': '已按 provider 能力映射',
      'function_calling': '已控制本轮 tools 注入',
      'max_context_unlocked': '已允许预设上下文覆盖模型默认值',
      'min_p': '已按 provider 能力映射',
      'openai_max_context': '已用于本地上下文裁剪',
      'openai_max_tokens': '已映射为 provider 输出上限',
      'presence_penalty': '已按 provider 能力映射',
      'prompt_order': '已用于 prompt 组装顺序',
      'prompts': '已用于 canonical messages 组装',
      'reasoning_effort': '已按 provider 能力映射',
      'repetition_penalty': '已按 provider 能力映射',
      'seed': '已按 provider 能力映射',
      'squash_system_messages': '已合并相邻无 name 的 system 消息',
      'stream_openai': '已用于本轮流式请求策略',
      'temperature': '已覆盖模型默认值',
      'top_a': '已按 provider 能力映射',
      'top_k': '已按 provider 能力映射',
      'top_p': '已覆盖模型默认值',
      'use_sysprompt': '已用于 Claude/Gemini system 渲染策略',
    };
    const normalSendNotApplicable = <String, String>{
      'assistant_impersonation': '仅 impersonation 模式使用，普通发送不适用',
      'bias_preset_selected': '酒馆 UI 选中状态，不影响请求',
      'continue_nudge_prompt': '仅 continue 模式使用',
      'continue_postfix': '仅 continue 模式使用',
      'continue_prefill': '仅 continue 模式使用',
      'group_nudge_prompt': '仅群聊使用',
      'impersonation_prompt': '仅 impersonation 模式使用',
      'new_group_chat_prompt': '仅群聊首轮使用',
      'request_image_aspect_ratio': '本轮不是酒馆图像请求',
      'request_image_resolution': '本轮不是酒馆图像请求',
      'send_if_empty': '三个回归预设均为空，普通发送不适用',
      'tool_call_recurse_limit': 'function_calling=false 时不适用',
      'tool_reasoning_mode': '三个回归预设均为 disabled',
    };

    final result = <SillyTavernParameterCompatibility>[];
    for (final field
        in body.keys.map((key) => key.toString()).toList()..sort()) {
      if (applied.containsKey(field)) {
        final noOpReason = _supportedNoOpReason(field, body[field]);
        result.add(
          SillyTavernParameterCompatibility(
            field: field,
            status: noOpReason == null
                ? SillyTavernParameterStatus.applied
                : SillyTavernParameterStatus.notApplicable,
            reason: noOpReason ?? applied[field]!,
          ),
        );
        continue;
      }
      if (normalSendNotApplicable.containsKey(field)) {
        result.add(
          SillyTavernParameterCompatibility(
            field: field,
            status: SillyTavernParameterStatus.notApplicable,
            reason: normalSendNotApplicable[field]!,
          ),
        );
        continue;
      }
      final dynamic value = body[field];
      final isDefaultOnly = switch (field) {
        'enable_web_search' ||
        'media_inlining' ||
        'request_images' ||
        'show_thoughts' => value != true,
        'inline_image_quality' ||
        'verbosity' => _string(value).isEmpty || _string(value) == 'auto',
        'n' => _nullableInt(value) == 1,
        'names_behavior' => _nullableInt(value) == 0,
        'personality_format' =>
          _stringPreservingWhitespace(value) == '{{personality}}',
        'scenario_format' =>
          _stringPreservingWhitespace(value) == '{{scenario}}',
        'wi_format' => _stringPreservingWhitespace(value) == '{0}',
        'new_chat_prompt' || 'new_example_chat_prompt' => true,
        _ => false,
      };
      result.add(
        SillyTavernParameterCompatibility(
          field: field,
          status: isDefaultOnly
              ? SillyTavernParameterStatus.notApplicable
              : SillyTavernParameterStatus.intentionallyUnsupported,
          reason: isDefaultOnly
              ? '当前值是默认/空值，对普通发送无额外效果'
              : '当前 AIcove 请求模式不执行该酒馆能力',
        ),
      );
    }
    _addExtensionCompatibility(body['extensions'], result);
    return result;
  }

  String? _supportedNoOpReason(String field, dynamic value) {
    final isNoOp = switch (field) {
      'assistant_prefill' => _stringPreservingWhitespace(value).trim().isEmpty,
      'frequency_penalty' || 'presence_penalty' => _finiteDouble(value) == 0,
      'min_p' || 'top_a' => _finiteDouble(value) == 0,
      'top_k' => _nullableInt(value) == 0,
      'repetition_penalty' => _finiteDouble(value) == 1,
      'seed' => (_nullableInt(value) ?? -1) < 0,
      'reasoning_effort' =>
        _string(value).isEmpty || _string(value).toLowerCase() == 'auto',
      'squash_system_messages' => value != true,
      _ => false,
    };
    return isNoOp ? '当前值是默认/空值，本轮不会额外改变请求' : null;
  }

  void _addExtensionCompatibility(
    dynamic rawExtensions,
    List<SillyTavernParameterCompatibility> result,
  ) {
    if (rawExtensions is! Map) return;
    if (rawExtensions['tavern_helper'] != null) {
      result.add(
        const SillyTavernParameterCompatibility(
          field: 'extensions.tavern_helper',
          status: SillyTavernParameterStatus.intentionallyUnsupported,
          reason: '不执行浏览器脚本加载器；SPreset 纯逻辑配置由 QuickJS 宿主处理',
        ),
      );
    }
    final sPreset = rawExtensions['SPreset'];
    if (sPreset is! Map) return;
    final chatSquash = sPreset['ChatSquash'];
    if (chatSquash is Map) {
      result.add(
        SillyTavernParameterCompatibility(
          field: 'extensions.SPreset.ChatSquash',
          status:
              chatSquash['enabled'] == true ||
                  chatSquash['squashed_post_script_enable'] == true
              ? SillyTavernParameterStatus.applied
              : SillyTavernParameterStatus.notApplicable,
          reason:
              chatSquash['enabled'] == true ||
                  chatSquash['squashed_post_script_enable'] == true
              ? 'QuickJS 执行消息合并及原始后处理函数；未支持的选项会阻止发送并报错'
              : '扩展声明为 disabled',
        ),
      );
    }
    if (sPreset['MacroNest'] == true) {
      result.add(
        const SillyTavernParameterCompatibility(
          field: 'extensions.SPreset.MacroNest',
          status: SillyTavernParameterStatus.intentionallyUnsupported,
          reason: '第三方宏脚本不执行',
        ),
      );
    }
    for (final field in ['OutputPreprocessing', 'ForcedPostProcessing']) {
      if (sPreset[field] is Map) {
        result.add(
          SillyTavernParameterCompatibility(
            field: 'extensions.SPreset.$field',
            status: SillyTavernParameterStatus.applied,
            reason: 'QuickJS 请求级宿主处理；未支持的配置明确报错',
          ),
        );
      }
    }
    final toolBindings = sPreset['ToolBindings'];
    if (toolBindings is Map && toolBindings.isNotEmpty) {
      result.add(
        const SillyTavernParameterCompatibility(
          field: 'extensions.SPreset.ToolBindings',
          status: SillyTavernParameterStatus.applied,
          reason: '按启用的 prompt 节点执行原始工具工厂与 action，需要模型支持工具调用',
        ),
      );
    }
  }

  String _normalizeRole(
    dynamic value,
    List<String> warnings,
    String identifier,
  ) {
    final role = _string(value).toLowerCase();
    if (role.isEmpty) return 'system';
    if (role == 'system' || role == 'user' || role == 'assistant') return role;
    warnings.add('$identifier 使用了不支持的 role=$role，已按 system 处理');
    return 'system';
  }

  static String _string(dynamic value) => value?.toString().trim() ?? '';

  static String _stringPreservingWhitespace(dynamic value) =>
      value is String ? value : '';

  static String? _nullableString(dynamic value) {
    final text = _string(value);
    return text.isEmpty ? null : text;
  }

  static int _int(dynamic value, {required int fallback}) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static int? _nullableInt(dynamic value, {int? min, int? max}) {
    final parsed = value is num
        ? value.toInt()
        : int.tryParse(value?.toString() ?? '');
    if (parsed == null ||
        (min != null && parsed < min) ||
        (max != null && parsed > max)) {
      return null;
    }
    return parsed;
  }

  static double? _finiteDouble(dynamic value) {
    final parsed = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '');
    return parsed != null && parsed.isFinite ? parsed : null;
  }

  static double? _boundedDouble(
    dynamic value, {
    required double min,
    required double max,
  }) {
    final parsed = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '');
    if (parsed == null || !parsed.isFinite || parsed < min || parsed > max) {
      return null;
    }
    return parsed;
  }

  static List<String> _stringList(dynamic value) {
    if (value is! List) return const [];
    return value
        .map((item) => item?.toString().trim() ?? '')
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  static List<String> _stringListPreservingWhitespace(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<String>()
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }
}

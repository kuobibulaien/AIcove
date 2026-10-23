import 'dart:convert';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show ReversibleChange, ToolEffect;

import '../../../core/api/providers/google_api_mode.dart'
    show kGeminiDeveloperApiBase;
import '../../../core/api/providers/provider_chat_api_path.dart'
    show copyCustomConfigWithProviderChatApiPath;
import '../../agent_plugins/file_change_journal.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../../settings/app_settings.dart';
import 'assistant_cards.dart';
import 'assistant_review.dart';
import 'assistant_tool_group.dart';

const assistantProviderChangeKind = 'assistant.provider';

/// Chat formats a new channel can use, as in the add-channel sheet.
const kAssistantChatFormats =
    <String, ({String label, String baseUrl, String apiPath})>{
      'openai': (
        label: 'OpenAI 兼容（DeepSeek、OpenRouter、硅基流动、各家中转等大多数服务）',
        baseUrl: 'https://api.openai.com/v1',
        apiPath: '/chat/completions',
      ),
      'claude': (
        label: 'Claude（Anthropic）',
        baseUrl: 'https://api.anthropic.com/v1',
        apiPath: '/messages',
      ),
      'gemini': (
        label: 'Gemini（Google）',
        baseUrl: kGeminiDeveloperApiBase,
        apiPath: '/models/{model}:generateContent',
      ),
    };

/// A chat channel the assistant prepared; it is created when the user
/// pastes its key into the card.
class ProviderDraft {
  const ProviderDraft({
    required this.format,
    required this.baseUrl,
    this.displayName,
  });

  final String format;
  final String baseUrl;
  final String? displayName;
}

/// Creates the channel of [draft] with [apiKey], fetching its model list the
/// way the add-channel sheet does. A channel whose list cannot be fetched is
/// still saved, with no models.
Future<void> createProviderFromDraft(
  AppSettingsNotifier notifier,
  Future<AppSettings> Function() load,
  ProviderDraft draft,
  String apiKey,
) async {
  final format = kAssistantChatFormats[draft.format]!;
  final customConfig = copyCustomConfigWithProviderChatApiPath({
    'requestFormat': draft.format,
  }, format.apiPath);
  var models = const <String>[];
  try {
    models = await notifier.previewProviderModels(
      providerId: draft.format,
      apiKey: apiKey,
      apiBaseUrl: draft.baseUrl,
      customConfig: customConfig,
    );
  } catch (_) {
    // Saved without models; the assistant can refresh the list later.
  }
  await notifier.importCustomModel(
    name: null,
    apiKey: apiKey,
    apiBaseUrl: draft.baseUrl,
    provider: draft.format,
    displayName: draft.displayName,
    allModels: models,
    visibleModels: _defaultVisible(models),
    customConfig: customConfig,
    capabilities: const ['chat'],
  );
}

/// One model of each kind, as the add-channel sheet picks them.
List<String> _defaultVisible(List<String> models) {
  final picked = <String>[];
  final kinds = <ModelType>{};
  for (final model in models) {
    if (kinds.add(ModelType.inferFromModelId(model))) picked.add(model);
  }
  return picked;
}

/// Channels and their models (ADR0073 full access, batch P2). Keys never
/// pass through here: a new channel or a new key goes through a card.
class AssistantProviderTools extends AssistantToolGroup {
  AssistantProviderTools({
    required this.current,
    required this.load,
    required this.notifier,
    required this.journal,
    required this.cards,
    required this.primaryKey,
    required this.testModel,
    this.onChanged,
  });

  /// The settings now, without waiting; null before they have loaded.
  final AppSettings? Function() current;
  final Future<AppSettings> Function() load;
  final AppSettingsNotifier Function() notifier;
  final FileChangeJournal journal;
  final AssistantCardsNotifier Function() cards;
  final String Function(ProviderAuth provider) primaryKey;
  final Future<String> Function(ProviderAuth provider, String modelId)
  testModel;
  final void Function()? onChanged;

  static const addProvider = 'aicove_add_provider';
  static const updateProvider = 'aicove_update_provider';
  static const listRemoteModels = 'aicove_list_remote_models';
  static const setModels = 'aicove_set_provider_models';
  static const testProvider = 'aicove_test_provider';
  static const deleteProvider = 'aicove_delete_provider';

  static const _providerId = {
    'type': 'string',
    'description': 'aicove_list_providers 给出的渠道 id',
  };

  @override
  List<AITool> tools() => [
    assistantTool(
      addProvider,
      '新建一个聊天渠道：在聊天页放一张卡片，用户粘贴 Key 后自动创建渠道、拉取模型列表。'
      '格式：${[for (final e in kAssistantChatFormats.entries) '${e.key}＝${e.value.label}'].join('；')}。'
      'api_base_url 不填就用该格式的官方地址；用户说了服务商（如 DeepSeek 是 https://api.deepseek.com）就填它的地址。'
      '卡片填好之前什么都没改；之后用 aicove_list_providers 看新渠道。',
      {
        'format': {
          'type': 'string',
          'enum': kAssistantChatFormats.keys.toList(),
        },
        'api_base_url': {'type': 'string'},
        'display_name': {'type': 'string', 'description': '渠道显示名，如「DeepSeek」'},
      },
      ['format'],
      ToolEffect.readDiagnostic,
      _add,
    ),
    assistantTool(
      updateProvider,
      '修改渠道：显示名、接口地址、启用／停用、是否禁用工具调用。只传要改的字段。可撤销；改接口地址默认直接生效。'
      '换 Key 用 aicove_request_key。',
      {
        'provider_id': _providerId,
        'display_name': {'type': 'string'},
        'api_base_url': {'type': 'string'},
        'enabled': {'type': 'boolean'},
        'disable_tool_calling': {'type': 'boolean'},
      },
      ['provider_id'],
      ToolEffect.write,
      _update,
    ),
    assistantTool(
      listRemoteModels,
      '用渠道已填的 Key 向服务商拉取最新的模型列表（不保存），并标出哪些已在可选列表里。',
      {'provider_id': _providerId},
      ['provider_id'],
      ToolEffect.readDiagnostic,
      _listRemote,
    ),
    assistantTool(
      setModels,
      '设置渠道里可选的模型（聊天页和默认模型里能选到的那些）：visible 是完整的新列表，'
      '不在渠道里的模型会加进去。可撤销。',
      {
        'provider_id': _providerId,
        'visible': {
          'type': 'array',
          'items': {'type': 'string'},
        },
      },
      ['provider_id', 'visible'],
      ToolEffect.write,
      _setModels,
    ),
    assistantTool(
      testProvider,
      '用渠道已填的 Key 给一个模型发一条极短的测试请求，返回成功与否和原因（如 Key 不对、余额不足、地址错）。',
      {
        'provider_id': _providerId,
        'model': {'type': 'string', 'description': '不填就用渠道里第一个可选模型'},
      },
      ['provider_id'],
      ToolEffect.readDiagnostic,
      _test,
    ),
    assistantTool(
      deleteProvider,
      '删除渠道（连同 Key 和模型列表），不能撤销，开启「修改前每次问我」后需确认。',
      {'provider_id': _providerId},
      ['provider_id'],
      ToolEffect.write,
      _delete,
    ),
  ];

  @override
  AssistantRisk riskOf(String toolName, Map<String, dynamic> args) {
    switch (toolName) {
      case addProvider || listRemoteModels || testProvider:
        return AssistantRisk.readOnly;
      case deleteProvider:
        return AssistantRisk.major;
      case updateProvider:
        // Chat content would go to another address.
        if (args['api_base_url'] != null) return AssistantRisk.major;
        if (args['enabled'] == false) return AssistantRisk.review;
        return AssistantRisk.reversible;
      default:
        return AssistantRisk.reversible;
    }
  }

  @override
  ApprovalPrompt describe(String toolName, Map<String, dynamic> args) {
    final id = args['provider_id'];
    final settings = current();
    final name = settings?.getProvider('$id')?.displayName ?? '$id';
    final isDefault =
        settings != null &&
        settings.getModelProviderId(settings.defaultModelName) == id;
    return switch (toolName) {
      deleteProvider => ApprovalPrompt(
        title: '删除渠道「$name」',
        detail: isDefault
            ? '这是默认聊天模型所在的渠道，删掉后聊天会用不了，Key 也会一起删除，不能撤销'
            : 'Key 和模型列表会一起删除，不能撤销',
      ),
      updateProvider when args['api_base_url'] != null => ApprovalPrompt(
        title: '把渠道「$name」的接口地址改成 ${args['api_base_url']}',
        detail: '之后这个渠道的聊天会发到新地址，可以在聊天页撤销',
      ),
      _ => ApprovalPrompt(
        title: '修改渠道「$name」',
        detail: '可以在聊天页撤销',
      ),
    };
  }

  Future<Map<String, Object?>> _add(Map<String, dynamic> args) async {
    final format = '${args['format']}';
    final known = kAssistantChatFormats[format];
    if (known == null) return assistantToolError('不支持的格式：$format');
    final url = _url(args['api_base_url']) ?? known.baseUrl;
    if (Uri.tryParse(url)?.hasScheme != true) {
      return assistantToolError('接口地址不对：$url');
    }
    final name = '${args['display_name'] ?? ''}'.trim();
    cards().requestNewProvider(
      ProviderDraft(
        format: format,
        baseUrl: url,
        displayName: name.isEmpty ? null : name,
      ),
    );
    return {
      'ok': true,
      'card': '已在聊天页放了一张「新建渠道」卡片，用户粘贴 Key 后自动创建并拉取模型',
    };
  }

  static String? _url(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  Future<({ProviderAuth? provider, Map<String, Object?>? error})> _provider(
    Map<String, dynamic> args,
  ) async {
    final provider = (await load()).getProvider('${args['provider_id']}');
    return provider == null
        ? (
            provider: null,
            error: assistantToolError('没有这个渠道：${args['provider_id']}'),
          )
        : (provider: provider, error: null);
  }

  Future<Map<String, Object?>> _update(Map<String, dynamic> args) async {
    final found = await _provider(args);
    final provider = found.provider;
    if (provider == null) return found.error!;
    final url = _url(args['api_base_url']);
    if (url != null && Uri.tryParse(url)?.hasScheme != true) {
      return assistantToolError('接口地址不对：$url');
    }
    final name = args['display_name']?.toString().trim();
    return _commit(updateProvider, provider, {
      if (name != null && name.isNotEmpty) 'display_name': name,
      'api_base_url': ?url,
      if (args['enabled'] is bool) 'enabled': args['enabled'],
      if (args['disable_tool_calling'] is bool)
        'disable_tool_calling': args['disable_tool_calling'],
    });
  }

  Future<Map<String, Object?>> _listRemote(Map<String, dynamic> args) async {
    final found = await _provider(args);
    final provider = found.provider;
    if (provider == null) return found.error!;
    final key = primaryKey(provider);
    if (key.isEmpty) {
      return assistantToolError('这个渠道还没填 Key，先用 aicove_request_key 请用户填');
    }
    try {
      final models = await notifier().previewProviderModels(
        providerId: provider.id,
        apiKey: key,
        apiBaseUrl: provider.apiBaseUrl,
        customConfig: provider.customConfig,
      );
      final visible = provider.visibleModels.toSet();
      return _scrub(provider, {
        'count': models.length,
        'models': [
          for (final model in models.take(300))
            {'id': model, if (visible.contains(model)) 'visible': true},
        ],
        if (models.length > 300) 'note': '只列出前 300 个',
      });
    } catch (error) {
      return _scrub(provider, assistantToolError('拉取失败：$error'));
    }
  }

  Future<Map<String, Object?>> _setModels(Map<String, dynamic> args) async {
    final found = await _provider(args);
    final provider = found.provider;
    if (provider == null) return found.error!;
    final visible = <String>[
      for (final model in (args['visible'] as List? ?? const []))
        if ('$model'.trim().isNotEmpty) '$model'.trim(),
    ].toSet().toList();
    final all = [
      ...provider.models,
      for (final model in visible)
        if (!provider.models.contains(model)) model,
    ];
    return _commit(setModels, provider, {
      'models': all,
      'visible': visible,
      'hidden': [
        for (final model in all)
          if (!visible.contains(model)) model,
      ],
    });
  }

  Future<Map<String, Object?>> _test(Map<String, dynamic> args) async {
    final found = await _provider(args);
    final provider = found.provider;
    if (provider == null) return found.error!;
    final key = primaryKey(provider);
    if (key.isEmpty) {
      return assistantToolError('这个渠道还没填 Key，先用 aicove_request_key 请用户填');
    }
    final model = '${args['model'] ?? ''}'.trim().isNotEmpty
        ? '${args['model']}'.trim()
        : provider.visibleModels.firstOrNull ?? provider.models.firstOrNull;
    if (model == null) return assistantToolError('渠道里还没有模型，先拉取模型列表');
    try {
      final reply = await testModel(provider, model);
      return _scrub(provider, {
        'ok': true,
        'model': model,
        'reply': reply.length > 200 ? reply.substring(0, 200) : reply,
      });
    } catch (error) {
      return _scrub(provider, {'ok': false, 'model': model, 'error': '$error'});
    }
  }

  /// Removes every key the channel holds now from [result]: the request ran
  /// with the stored keys, which may be newer than the run's own redactor.
  Future<Map<String, Object?>> _scrub(
    ProviderAuth provider,
    Map<String, Object?> result,
  ) async {
    final latest = (await load()).getProvider(provider.id) ?? provider;
    final keys = {
      for (final key in [
        ...provider.apiKeys,
        ...latest.apiKeys,
        primaryKey(provider),
        primaryKey(latest),
      ]) ...[key, key.trim()],
    }.where((key) => key.isNotEmpty).toList()
      // Longest first, so a key inside another is not left half-replaced.
      ..sort((a, b) => b.length.compareTo(a.length));
    Object? clean(Object? value) => switch (value) {
      String() => keys.fold<String>(
        value,
        (text, key) => text.replaceAll(key, '***'),
      ),
      Map() => {
        for (final MapEntry(:key, value: item) in value.entries)
          clean(key): clean(item),
      },
      List() => [for (final item in value) clean(item)],
      _ => value,
    };
    return (clean(result)! as Map).cast<String, Object?>();
  }

  Future<Map<String, Object?>> _delete(Map<String, dynamic> args) async {
    final found = await _provider(args);
    final provider = found.provider;
    if (provider == null) return found.error!;
    await notifier().deleteProvider(provider.id);
    onChanged?.call();
    return {'ok': true, 'change': '删除了渠道「${provider.displayName ?? provider.id}」'};
  }

  /// Records only the fields that change, so undo restores those and
  /// never writes back fields someone else changed meanwhile.
  Future<Map<String, Object?>> _commit(
    String toolName,
    ProviderAuth provider,
    Map<String, Object?> wanted,
  ) async {
    final now = providerSnapshot(provider);
    final changed = [
      for (final MapEntry(:key, :value) in wanted.entries)
        if (!sameProviderState({key: now[key]}, {key: value})) key,
    ];
    if (changed.isEmpty) return {'ok': true, 'change': '没有变化'};
    final before = {
      'provider_id': provider.id,
      for (final key in changed) key: now[key],
    };
    final after = {
      'provider_id': provider.id,
      for (final key in changed) key: wanted[key],
    };
    final description =
        '修改了渠道「${provider.displayName ?? provider.id}」'
        '（${[for (final key in changed) _labels[key] ?? key].join('、')}）';
    await journal.commit(
      toolName,
      ReversibleChange(
        kind: assistantProviderChangeKind,
        description: description,
        before: before,
        after: after,
      ),
    );
    onChanged?.call();
    return {'ok': true, 'change': description, 'undo': '用户可以在聊天页撤销这次修改'};
  }

  static const _labels = {
    'display_name': '显示名',
    'api_base_url': '接口地址',
    'enabled': '启用',
    'disable_tool_calling': '工具调用',
    'models': '模型列表',
    'visible': '可选模型',
    'hidden': '隐藏模型',
  };
}

/// What undo restores of a channel; never its keys.
Map<String, Object?> providerSnapshot(ProviderAuth provider) => {
  'provider_id': provider.id,
  'display_name': provider.displayName ?? '',
  'api_base_url': provider.apiBaseUrl,
  'enabled': provider.enabled,
  'disable_tool_calling': provider.disableToolCalling,
  'models': provider.models,
  'visible': provider.visibleModels,
  'hidden': provider.hiddenModels,
};

bool sameProviderState(Map<String, Object?> a, Map<String, Object?> b) =>
    jsonEncode(a) == jsonEncode(b);

/// Writes a channel snapshot back, field by field, only where it differs.
class AssistantProviderApplier extends CheckedChangeApplier {
  AssistantProviderApplier({required this.notifier});

  final AppSettingsNotifier Function() notifier;

  Future<ProviderAuth> _provider(Map<String, Object?> state) async =>
      (await notifier().readStored()).getProvider('${state['provider_id']}') ??
      (throw StateError('渠道已经不在了：${state['provider_id']}'));

  /// True when every field [state] names still holds its value.
  @override
  Future<bool> isCurrent(Map<String, Object?> state) async {
    final provider = (await notifier().readStored()).getProvider(
      '${state['provider_id']}',
    );
    if (provider == null) return false;
    final now = providerSnapshot(provider);
    return state.keys.every(
      (key) => sameProviderState({key: now[key]}, {key: state[key]}),
    );
  }

  /// Checked and written under the settings write lock, so a manual edit
  /// cannot land between the check and the undo.
  @override
  Future<bool> applyIfCurrent(
    Map<String, Object?> expected,
    Map<String, Object?> state,
  ) => notifier().transaction(() => super.applyIfCurrent(expected, state));

  /// Writes only the fields [state] names.
  @override
  Future<void> apply(Map<String, Object?> state) =>
      notifier().transaction(() async {
        final now = providerSnapshot(await _provider(state));
        final n = notifier();
        final id = '${state['provider_id']}';
        bool changed(String key) =>
            state.containsKey(key) &&
            !sameProviderState({key: now[key]}, {key: state[key]});
        if (changed('display_name') || changed('api_base_url')) {
          await n.editProvider(
            providerId: id,
            displayName: changed('display_name')
                ? '${state['display_name']}'
                : null,
            apiBaseUrl: changed('api_base_url')
                ? '${state['api_base_url']}'
                : null,
          );
        }
        if (changed('enabled')) {
          await n.setProviderEnabled(id, state['enabled'] == true);
        }
        if (changed('disable_tool_calling')) {
          await n.setProviderDisableToolCalling(
            id,
            state['disable_tool_calling'] == true,
          );
        }
        if (changed('models') || changed('visible') || changed('hidden')) {
          List<String> list(String key) => [
            for (final item in (state[key] ?? now[key]) as List? ?? const [])
              '$item',
          ];
          await n.updateProviderModels(
            providerId: id,
            allModels: list('models'),
            visibleModels: list('visible'),
            hiddenModels: list('hidden'),
          );
        }
      });
}

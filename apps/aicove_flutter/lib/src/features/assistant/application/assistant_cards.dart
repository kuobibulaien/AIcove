import 'dart:convert';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show ToolEffect;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../plugins/domain/handlers/ai_tool.dart';
import '../../settings/app_settings.dart';
import '../domain/assistant_onboarding.dart' show providerHasApiKey;

/// A card the assistant puts above the composer of its chat, for the user to
/// act on whenever they like (ADR0073, batch T3b). Tools that add one return
/// at once; nothing waits on the user.
sealed class AssistantCard {
  const AssistantCard(this.id);
  final String id;
}

/// A button to a page in the app. [target] is one of [kAssistantPages];
/// [targetId] names the role, channel or preset for pages that need one.
class AssistantPageLink extends AssistantCard {
  const AssistantPageLink(super.id, this.target, this.label, {this.targetId});

  final String target;
  final String label;
  final String? targetId;
}

/// An API key input for one channel. The key goes from the field straight to
/// the channel settings; the model only learns that the card was shown.
class AssistantKeyRequest extends AssistantCard {
  const AssistantKeyRequest(super.id, this.providerId, this.providerName);

  final String providerId;
  final String providerName;
}

/// Pages the assistant can link to, with what the target id names.
const kAssistantPages = <String, ({String label, String? needs})>{
  'models': (label: '设置 · 模型', needs: null),
  'default_model': (label: '默认模型设置', needs: null),
  'provider': (label: '渠道详情', needs: 'provider'),
  'general': (label: '设置 · 通用', needs: null),
  'plugins': (label: '设置 · 插件', needs: null),
  'profile': (label: '个人资料', needs: null),
  'role_edit': (label: '角色编辑', needs: 'role'),
  'role_context': (label: '联系人上下文', needs: 'role'),
  'preset': (label: '酒馆预设详情', needs: 'preset'),
};

class AssistantCardsNotifier extends Notifier<List<AssistantCard>> {
  int _sequence = 0;

  @override
  List<AssistantCard> build() => const [];

  String _nextId() => 'card_${_sequence++}';

  void showPage(String target, String label, {String? targetId}) {
    // One link per page: a repeated suggestion replaces the old one.
    state = [
      for (final card in state)
        if (card is! AssistantPageLink ||
            card.target != target ||
            card.targetId != targetId)
          card,
      AssistantPageLink(_nextId(), target, label, targetId: targetId),
    ];
  }

  void requestKey(String providerId, String providerName) {
    state = [
      for (final card in state)
        if (card is! AssistantKeyRequest || card.providerId != providerId) card,
      AssistantKeyRequest(_nextId(), providerId, providerName),
    ];
  }

  void dismiss(String id) => state = [
    for (final card in state)
      if (card.id != id) card,
  ];
}

final assistantCardsProvider =
    NotifierProvider<AssistantCardsNotifier, List<AssistantCard>>(
      AssistantCardsNotifier.new,
    );

/// Tools that hand the user a card, and the channel list they need.
class AssistantCardTools {
  AssistantCardTools({
    required this.settings,
    required this.cards,
    required this.roleExists,
    required this.presetExists,
  });

  final Future<AppSettings> Function() settings;
  final AssistantCardsNotifier Function() cards;

  /// Visible roles only: a role in the privacy space does not exist here.
  final Future<bool> Function(String roleId) roleExists;
  final Future<bool> Function(String presetId) presetExists;

  static const listProviders = 'aicove_list_providers';
  static const requestKey = 'aicove_request_key';
  static const openPage = 'aicove_open_page';

  static const names = {listProviders, requestKey, openPage};

  List<AITool> tools() => [
    _tool(
      listProviders,
      '列出模型渠道：id、名字、是否启用、有没有填 Key（看不到 Key 本身）、能力、可见模型，以及当前默认聊天模型。',
      const {},
      const [],
      ToolEffect.readDiagnostic,
      _listProviders,
    ),
    _tool(
      requestKey,
      '在聊天页显示一张 API Key 输入卡片，用户把 Key 粘贴进去就会保存到这个渠道（替换原有 Key），渠道没启用的会同时启用。'
      '你看不到 Key；不要让用户把 Key 发在聊天里。卡片会一直留着，用户填好后再继续。',
      {
        'provider_id': {
          'type': 'string',
          'description': 'aicove_list_providers 给出的渠道 id',
        },
      },
      ['provider_id'],
      ToolEffect.readDiagnostic,
      _requestKey,
    ),
    _tool(
      openPage,
      '在聊天页显示一个「去看看」按钮，带用户打开 App 里的某个页面：'
      '${[for (final e in kAssistantPages.entries) '${e.key}（${e.value.label}${e.value.needs == null ? '' : '，需要 id'}）'].join('、')}。'
      'id：provider 用渠道 id，role_edit／role_context 用角色 id，preset 用预设 id。',
      {
        'target': {
          'type': 'string',
          'enum': [...kAssistantPages.keys],
        },
        'id': {'type': 'string', 'description': '页面需要的 id'},
      },
      ['target'],
      ToolEffect.readDiagnostic,
      _openPage,
    ),
  ];

  AITool _tool(
    String name,
    String description,
    Map<String, Object> properties,
    List<String> required,
    ToolEffect effect,
    Future<Map<String, Object?>> Function(Map<String, dynamic> args) run,
  ) => AITool(
    name: name,
    description: description,
    parameters: const {},
    inputSchema: {
      'type': 'object',
      'properties': properties,
      'required': required,
    },
    effect: effect,
    handler: (args) async => jsonEncode(await run(args)),
  );

  Future<Map<String, Object?>> _listProviders(Map<String, dynamic> _) async {
    final s = await settings();
    return {
      'default_chat_model': s.defaultModelName,
      'providers': [
        for (final provider in s.providers)
          {
            'id': provider.id,
            'name': provider.displayName ?? provider.id,
            'enabled': provider.enabled,
            'has_key': providerHasApiKey(provider),
            'capabilities': provider.capabilities,
            'models': provider.visibleModels.isEmpty
                ? provider.models
                : provider.visibleModels,
          },
      ],
    };
  }

  Future<Map<String, Object?>> _requestKey(Map<String, dynamic> args) async {
    final id = (args['provider_id'] ?? '').toString().trim();
    final provider = (await settings()).getProvider(id);
    if (provider == null) {
      return {'error': 'not_found', 'message': '没有这个渠道：$id'};
    }
    cards().requestKey(provider.id, provider.displayName ?? provider.id);
    return {'shown': true, 'note': '卡片已显示，等用户自己填写；保存后不会通知你'};
  }

  Future<Map<String, Object?>> _openPage(Map<String, dynamic> args) async {
    final target = (args['target'] ?? '').toString();
    final page = kAssistantPages[target];
    if (page == null) return {'error': 'invalid', 'message': '没有这个页面：$target'};
    final id = (args['id'] ?? '').toString().trim();
    if (page.needs != null) {
      final exists =
          id.isNotEmpty &&
          switch (page.needs) {
            'role' => await roleExists(id),
            'preset' => await presetExists(id),
            _ => (await settings()).getProvider(id) != null,
          };
      if (!exists) {
        return {'error': 'not_found', 'message': '$target 需要一个有效的 id'};
      }
    }
    cards().showPage(
      target,
      page.label,
      targetId: page.needs == null ? null : id,
    );
    return {'shown': true};
  }
}

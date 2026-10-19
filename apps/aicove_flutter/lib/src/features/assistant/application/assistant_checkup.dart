import 'dart:convert';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show ToolEffect;

import '../../agent_context/domain/silly_tavern_preset.dart';
import '../../chat/domain/conversation.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../../settings/app_settings.dart';
import '../domain/assistant_onboarding.dart'
    show hasUsableChatModel, kAicoveAssistantId, providerHasApiKey;

/// One problem the checkup found. [text] is a fixed explanation built from
/// names and ids only, never from chat text, prompts or keys.
class CheckupFinding {
  const CheckupFinding(this.level, this.area, this.text, {this.roleId});

  /// `error` blocks a feature, `warning` probably hurts, `info` is worth
  /// knowing.
  final String level;
  final String area;
  final String text;
  final String? roleId;

  Map<String, Object?> toJson() => {
    'level': level,
    'area': area,
    'text': text,
    'role_id': ?roleId,
  };
}

/// Read-only health check of the user's setup (ADR0073, batch T4): the
/// usual reasons chatting goes wrong, gathered in one call so the assistant
/// can start a review from the list instead of guessing.
///
/// Roles in the privacy space are skipped.
class AssistantCheckup {
  AssistantCheckup({
    required this.settings,
    required this.roles,
    required this.presets,
    required this.voiceEnabled,
    required this.callUnavailable,
    Future<String?> Function()? defaultPresetId,
  }) : defaultPresetId = defaultPresetId ?? _none;

  static Future<String?> _none() async => null;

  final Future<AppSettings> Function() settings;
  final Future<List<Conversation>> Function() roles;
  final Future<List<SillyTavernPreset>> Function() presets;

  /// The global default tavern preset, used by roles that bind none.
  final Future<String?> Function() defaultPresetId;

  /// Whether the voice plugin is on globally; calls are not checked when off.
  final bool Function() voiceEnabled;

  /// Why a role cannot be called now (fixed text), or null; checks the
  /// configuration only.
  final Future<String?> Function(Conversation role) callUnavailable;

  static const toolName = 'aicove_checkup';

  /// Plugins that only work through tool calls.
  static const _toolPlugins = {'image': '绘图', 'web_search': '联网搜索'};

  List<AITool> tools() => [
    AITool(
      name: toolName,
      description:
          '体检：一次检查默认模型与渠道、每个角色的预设绑定、插件与预设冲突、正则授权、语音通话配置，'
          '列出发现的问题（error 会让功能用不了，warning 可能影响效果，info 供参考）。'
          '用户说「帮我看看哪里有问题」或排查前先跑一次。',
      parameters: const {},
      inputSchema: const {'type': 'object', 'properties': {}},
      effect: ToolEffect.readDiagnostic,
      handler: (_) async {
        final findings = await run();
        return jsonEncode({
          'findings': [for (final f in findings) f.toJson()],
          if (findings.isEmpty) 'summary': '没有发现问题',
        });
      },
    ),
  ];

  Future<List<CheckupFinding>> run() async {
    final s = await settings();
    final allPresets = await presets();
    final byId = {for (final p in allPresets) p.id: p};
    String? defaultId;
    var defaultBroken = false;
    try {
      defaultId = (await defaultPresetId())?.trim();
    } catch (_) {
      defaultBroken = true;
    }
    if (defaultId != null && defaultId.isEmpty) defaultId = null;
    final visible = [
      for (final role in await roles())
        if (!role.isHidden) role,
    ];
    final findings = <CheckupFinding>[
      if (!hasUsableChatModel(s))
        const CheckupFinding(
          'error',
          'model',
          '默认聊天模型不可用：它所在的渠道没启用、不能聊天或没填 Key，所有角色都发不出消息',
        ),
      for (final provider in s.providers)
        if (provider.enabled &&
            provider.capabilities.contains('chat') &&
            !providerHasApiKey(provider))
          CheckupFinding(
            'warning',
            'provider',
            '渠道「${provider.displayName ?? provider.id}」启用了但没填 Key，选它的模型会失败',
          ),
      if (defaultBroken)
        const CheckupFinding(
          'error',
          'preset',
          '酒馆插件配置损坏，没绑预设的角色发消息可能报错，需要在「设置 · 插件 · 酒馆相关 · 酒馆预设」重新保存',
        )
      else if (defaultId != null && !byId.containsKey(defaultId))
        const CheckupFinding(
          'error',
          'preset',
          '默认酒馆预设在本机找不到，没绑预设的角色发消息会报错，需要在「设置 · 插件 · 酒馆相关 · 酒馆预设」重新选择',
        ),
    ];

    for (final role in visible) {
      final name = '「${role.displayName}」';
      final plugins = role.enabledPlugins;
      bool uses(String id) => plugins == null || plugins.contains(id);
      final recipeId = role.recipeId?.trim();
      final bound = recipeId != null && recipeId.isNotEmpty;
      // The preset the next message uses: the role's own, else the default.
      final preset = bound
          ? byId[recipeId]
          : defaultId == null
          ? null
          : byId[defaultId];
      final presetLabel = bound ? '绑定的预设' : '默认预设';
      if (bound && preset == null) {
        findings.add(
          CheckupFinding(
            'error',
            'preset',
            '$name绑定的酒馆预设在本机找不到，发消息会报错，需要重新绑定或解除绑定',
            roleId: role.id,
          ),
        );
      }
      if (preset != null) {
        if (preset.functionCalling == false) {
          final blocked = [
            for (final entry in _toolPlugins.entries)
              if (uses(entry.key)) entry.value,
          ];
          if (blocked.isNotEmpty) {
            findings.add(
              CheckupFinding(
                'warning',
                'preset',
                '$name开了${blocked.join('、')}，但$presetLabel「${preset.name}」关闭了函数调用，这些插件用不了',
                roleId: role.id,
              ),
            );
          }
        }
        if (preset.regexScripts.isNotEmpty && !preset.regexAuthorized) {
          findings.add(
            CheckupFinding(
              'info',
              'preset',
              '$name$presetLabel「${preset.name}」有 ${preset.regexScripts.length} 条正则还没授权，现在都不执行',
              roleId: role.id,
            ),
          );
        }
      }
      if (plugins != null && plugins.isEmpty && role.id != kAicoveAssistantId) {
        findings.add(
          CheckupFinding(
            'info',
            'plugins',
            '$name一个插件都没开（记忆、语音、绘图、表情包等都不会生效）',
            roleId: role.id,
          ),
        );
      }
      if (voiceEnabled() && uses('tts') && role.id != kAicoveAssistantId) {
        final String? reason;
        try {
          reason = await callUnavailable(role);
        } catch (_) {
          findings.add(
            CheckupFinding(
              'info',
              'voice_call',
              '$name的通话配置检查出错，让用户点电话图标看提示',
              roleId: role.id,
            ),
          );
          continue;
        }
        if (reason != null) {
          findings.add(
            CheckupFinding(
              'info',
              'voice_call',
              '$name现在打不了电话：$reason',
              roleId: role.id,
            ),
          );
        }
      }
    }
    return findings;
  }
}

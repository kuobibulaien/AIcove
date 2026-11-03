import 'dart:convert';
import 'package:flutter/services.dart';
import '../domain/conversation.dart';
import '../domain/chat_display_policy.dart';
import '../domain/role_agent_mode.dart';

/// 预设角色加载器
class PresetCharactersLoader {
  static List<Conversation>? _cache;
  static final _firstMessages = <String, String>{};

  /// Opening text is seed metadata, not a second message store.
  static Future<String?> firstMessageFor(String id) async {
    await load();
    return _firstMessages[id];
  }

  static Conversation fromJson(
    Map<String, dynamic> json, {
    String personaPrompt = '',
  }) {
    final now = DateTime.now();
    return Conversation(
      id: json['id'] as String,
      title: json['displayName'] as String,
      displayName: json['displayName'] as String,
      description: json['description'] as String?,
      characterImage: json['characterImage'] as String?,
      avatarUrl: json['avatarUrl'] as String?,
      voiceFile: json['voiceFile'] as String?,
      personaPrompt: personaPrompt,
      agentMode:
          RoleAgentMode.fromValue(json['agentMode'] as String?) ??
          RoleAgentMode.chat,
      enabledPlugins:
          (json['enabledPlugins'] as List?)?.cast<String>() ??
          kDefaultRolePluginIds,
      chatDisplayStyle: ChatDisplayStyle.fromValue(
        json['chatDisplayStyle'] as String?,
      ),
      createdAt: now,
      updatedAt: now,
      isFavorite: false,
    );
  }

  /// 加载预设角色列表
  static Future<List<Conversation>> load() async {
    if (_cache != null) return _cache!;

    try {
      final jsonStr = await rootBundle.loadString(
        'assets/characters/preset_characters.json',
      );
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      final characters = (data['characters'] as List)
          .cast<Map<String, dynamic>>();

      final results = <Conversation>[];
      for (final json in characters) {
        // 读取提示词文件
        String personaPrompt = '';
        final promptFile = json['personaPromptFile'] as String?;
        if (promptFile != null) {
          try {
            personaPrompt = await rootBundle.loadString(promptFile);
          } catch (e) {
            print('[PresetCharactersLoader] 读取提示词文件失败 $promptFile: $e');
          }
        }

        final firstMessage = json['firstMessage'] as String?;
        if (firstMessage != null)
          _firstMessages[json['id'] as String] = firstMessage;
        results.add(fromJson(json, personaPrompt: personaPrompt));
      }

      _cache = results;
      return _cache!;
    } catch (e) {
      print('[PresetCharactersLoader] 加载失败: $e');
      return [];
    }
  }
}

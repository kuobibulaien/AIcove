import 'dart:convert';
import 'package:flutter/services.dart';
import '../domain/conversation.dart';

/// 预设角色加载器
class PresetCharactersLoader {
  static List<Conversation>? _cache;

  /// 加载预设角色列表
  static Future<List<Conversation>> load() async {
    if (_cache != null) return _cache!;

    try {
      final jsonStr = await rootBundle.loadString('assets/characters/preset_characters.json');
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      final characters = (data['characters'] as List).cast<Map<String, dynamic>>();

      final results = <Conversation>[];
      for (final json in characters) {
        final now = DateTime.now();

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

        results.add(Conversation(
          id: json['id'] as String,
          title: json['displayName'] as String,
          displayName: json['displayName'] as String,
          description: json['description'] as String?,
          characterImage: json['characterImage'] as String?,
          avatarUrl: json['avatarUrl'] as String?,
          personaPrompt: personaPrompt,
          createdAt: now,
          updatedAt: now,
          isFavorite: false,
        ));
      }

      _cache = results;
      return _cache!;
    } catch (e) {
      print('[PresetCharactersLoader] 加载失败: $e');
      return [];
    }
  }
}

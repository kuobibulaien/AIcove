// ADR0092 real-model check (opt-in): the per-model default packs steer a
// real chat model. Fish S2 → bracket tags inside <tts>; the natural-language
// image pack → an English description inside <image>. DeepSeek Flash;
// skipped unless DEEPSEEK_API_KEY is set.
@Tags(['real_model'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/features/chat/services/api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/builtin_prompt_packs.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/prompt_pack.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';

final String? _apiKey = Platform.environment['DEEPSEEK_API_KEY'];

Future<String> _reply(String system, String user) async =>
    (await createApiRunner().executeApiCall(
      config: ApiConfig(
        settings: mapUiModelsToAppSettings({}),
        modelFullId: 'openai:deepseek-flash',
        providerApiBase: 'https://api.deepseek.com',
        providerApiKey: _apiKey,
        customConfig: const {},
        modelTemperature: 0.7,
        messages: [
          {'role': 'system', 'content': system},
          {'role': 'user', 'content': user},
        ],
      ),
      sessionId: 'packs',
      userText: user,
      turnId: 'packs',
      responseProcessors: const [],
    )).replyText;

void main() {
  final library = PromptPackLibrary(builtins: kBuiltinPromptPacks);
  const persona = '你是纳西妲，须弥的小吉祥草王，温柔、好奇，喜欢用比喻。用中文和旅行者聊天。';

  test(
    'the Fish S2 pack gets bracket tags inside <tts>',
    () async {
      final pack = library.resolve(
        'tts',
        const PresetPromptBinding(),
        format: 'fish_audio',
        model: 's2-pro',
      );
      expect(pack.pack.id, 'builtin.tts.fish_s2');
      final system =
          '$persona\n\n${pack.render(PromptScopes.ttsChat, {'max_chars_per_chunk': 200, 'voice_frequency': 100})}';
      final reply = await _reply(system, '我今天考试没过，好难过……你能安慰我一下吗？');
      // ignore: avoid_print
      print('Fish S2：$reply');
      final tts = RegExp(r'<tts>([\s\S]*?)</tts>').allMatches(reply).toList();
      expect(tts, isNotEmpty);
      expect(tts.any((m) => RegExp(r'\[[^\]]+\]').hasMatch(m[1]!)), isTrue);
    },
    skip: _apiKey == null ? '需要 DEEPSEEK_API_KEY' : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'the natural-language image pack gets an English sentence in <image>',
    () async {
      final pack = library.resolve(
        'image',
        const PresetPromptBinding(),
        format: 'openai',
        model: 'gpt-image-1',
      );
      expect(pack.pack.id, 'builtin.image.natural');
      final system =
          '$persona\n\n${pack.render(PromptScopes.imageInline, {'default_width': 1024, 'default_height': 1024})}';
      final reply = await _reply(system, '给我拍一张你在森林里看书的照片吧！');
      // ignore: avoid_print
      print('自然语言：$reply');
      final image = RegExp(r'<image[^>]*>([\s\S]*?)</image>').firstMatch(reply);
      expect(image, isNotNull);
      final text = image![1]!;
      expect(RegExp(r'[A-Za-z]+ [A-Za-z]+ [A-Za-z]+').hasMatch(text), isTrue);
      // Sentences, not a comma-separated tag list.
      expect(RegExp(r'\b(a|an|the|is|with|in)\b').hasMatch(text), isTrue);
    },
    skip: _apiKey == null ? '需要 DEEPSEEK_API_KEY' : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'the ComfyUI pack gets an English sentence plus Danbooru tags in <image>',
    () async {
      final pack = library.resolve(
        'image',
        const PresetPromptBinding(),
        format: 'comfyui',
        model: 'template/zimage_turbo',
      );
      expect(pack.pack.id, 'builtin.image.comfyui');
      final system =
          '$persona\n\n${pack.render(PromptScopes.imageInline, {'default_width': 832, 'default_height': 1216, 'default_count': 1, 'default_steps': 28, 'default_guidance_scale': 5})}';
      final reply = await _reply(system, '给我拍一张你在森林里看书的照片吧！');
      // ignore: avoid_print
      print('ComfyUI 通用：$reply');
      final image = RegExp(r'<image[^>]*>([\s\S]*?)</image>').firstMatch(reply);
      expect(image, isNotNull);
      final raw = image![1]!.trim();
      final text = raw.startsWith('{')
          ? (jsonDecode(raw) as Map)['prompt'] as String
          : raw;
      // A sentence first, then comma-separated tags; no NovelAI weights.
      expect(RegExp(r'\b(a|an|the|is|with|in)\b').hasMatch(text), isTrue);
      expect(RegExp(r'\b1girl\b|\bsolo\b').hasMatch(text), isTrue);
      expect(text.contains('::') || text.contains('{') || text.contains('|'), isFalse);
    },
    skip: _apiKey == null ? '需要 DEEPSEEK_API_KEY' : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

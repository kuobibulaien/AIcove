import 'package:aicove_flutter/src/core/services/system_reminder_service.dart';
import 'package:aicove_flutter/src/features/agent_plugins/aicove_plugin.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_request_scope.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_runtime.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/builtin_prompt_packs.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/plugin_prompts.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/prompt_pack.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/prompt_pack_migration.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_request.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/settings/settings_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _refProvider = Provider<Ref>((ref) => ref);

void main() {
  late ProviderContainer container;
  late Ref ref;
  setUp(() {
    container = ProviderContainer();
    ref = container.read(_refProvider);
  });
  tearDown(() => container.dispose());

  // Auto call flow with a usable image channel: the snapshot itself offers
  // draw_image; only the route decides whether it reaches the request.
  final settings = mapUiModelsToAppSettings(const {}).copyWith(
    imageGenerationEnabled: true,
    callFlowSettings: const CallFlowSettings(mode: CallFlowMode.call),
    providers: const [
      ProviderAuth(
        id: 'nai',
        apiKeys: ['test-key'],
        apiBaseUrl: 'https://image.novelai.net',
        models: ['nai-diffusion-4-5-full'],
        visibleModels: ['nai-diffusion-4-5-full'],
        capabilities: ['image'],
        customConfig: {'requestFormat': 'novelai'},
      ),
    ],
    modelTypes: const {'nai-diffusion-4-5-full': 'image'},
  );

  PluginRequestScope scope({
    required bool fast,
    String customDrawingPrompt = '',
  }) {
    final library = PromptPackLibrary(builtins: kBuiltinPromptPacks);
    var binding = const PresetPromptBinding();
    if (customDrawingPrompt.isNotEmpty) {
      for (final section in roleDrawingSections(customDrawingPrompt)) {
        binding = binding.upsertSection(section);
      }
    }
    final runtime = PluginRuntime()
      ..install(ImagePlugin(const ImageConfig(), ref).agentPlugin);
    return runtime
        .requestScopes(
          runtime.snapshot(),
          runtime.selectForRole(null),
          PluginRequestInputs(
            ref: ref,
            settings: settings,
            imageConfig: const ImageConfig(),
            voiceRequest: VoiceRequest(ownerId: 'role'),
            pluginPrompts: const PluginPrompts(),
            history: const [],
            previousUserMessageTime: null,
            useFastImageRoute: fast,
            useStableImageRoute: !fast,
            supportsToolCalling: true,
            reminders: const SystemReminderService(),
            imagePrompts: library.resolve(
              'image',
              binding,
              format: 'novelai',
              model: 'nai-diffusion-4-5-full',
            ),
          ),
        )
        .single;
  }

  test('declares request and responses only', () {
    final runtime = PluginRuntime()
      ..install(ImagePlugin(const ImageConfig(), ref).agentPlugin);
    expect(runtime.plugin('image')!.capabilities,
        {AppCapability.request, AppCapability.responses});
  });

  test('a fast route resolved under auto call flow drops draw_image', () {
    expect(scope(fast: false).tools().map((t) => t.name), ['draw_image']);
    expect(scope(fast: true).tools(), isEmpty);
  });

  test('the stable route carries the preset drawing section into draw_image only',
      () {
    final stable = scope(fast: false, customDrawingPrompt: '只画水彩');
    final schemas = [
      for (final tool in stable.tools()) tool.toOpenAISchema(),
      {
        'type': 'function',
        'function': {'name': 'other', 'description': 'x', 'parameters': {}},
      },
    ];
    final rewritten = stable.rewriteToolSchemas(schemas);
    expect(rewritten.first.toString(), contains('【角色专属生图要求】'));
    expect(rewritten.first.toString(), contains('只画水彩'));
    expect(rewritten.last, schemas.last);

    final fast = scope(fast: true, customDrawingPrompt: '只画水彩');
    expect(fast.rewriteToolSchemas(schemas), same(schemas));
  });
}

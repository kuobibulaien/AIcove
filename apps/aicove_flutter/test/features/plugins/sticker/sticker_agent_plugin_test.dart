import 'package:aicove_flutter/src/core/services/system_reminder_service.dart';
import 'package:aicove_flutter/src/features/agent_plugins/aicove_plugin.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_request_context.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_request_scope.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_response.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_runtime.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/plugin_prompts.dart';
import 'package:aicove_flutter/src/features/plugins/sticker/sticker_config.dart';
import 'package:aicove_flutter/src/features/plugins/sticker/sticker_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_request.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/stickers/sticker_registry.dart';
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

  PluginRequestInputs inputs(PluginPrompts prompts) => PluginRequestInputs(
        ref: ref,
        settings: mapUiModelsToAppSettings(const {}),
        imageConfig: const ImageConfig(),
        voiceRequest: VoiceRequest(ownerId: 'role'),
        pluginPrompts: prompts,
        history: const [],
        previousUserMessageTime: null,
        useFastImageRoute: false,
        useStableImageRoute: true,
        supportsToolCalling: true,
        customDrawingPrompt: '',
        reminders: const SystemReminderService(),
      );

  test('declares request and responses only', () {
    final runtime =
        PluginRuntime.fromPlugins([StickerPlugin(const StickerConfig())]);
    expect(runtime.plugin('sticker')!.capabilities,
        {AppCapability.request, AppCapability.responses});
  });

  test('the prompt renders the request template with installed tags',
      () async {
    const template = '可用表情：{{tags}}';
    final runtime =
        PluginRuntime.fromPlugins([StickerPlugin(const StickerConfig())]);
    final scope = runtime
        .requestScopes(
          runtime.snapshot(),
          runtime.selectForRole(null),
          inputs(const PluginPrompts()
              .withText(PluginPromptSlot.sticker, template)),
        )
        .single;
    final prompt = await scope.prompt(
      const PluginRequestContext(userMessage: '', supportsToolCalling: true),
    );
    expect(
      prompt,
      await StickerPlugin(const StickerConfig(systemPromptTemplate: template))
          .buildSystemPrompt(),
    );
    expect(prompt, startsWith('可用表情：'));
    expect(scope.tools(), isEmpty);
  });

  test('replies: known tags become sticker events, as the legacy method did',
      () async {
    final registered = StickerPlugin(const StickerConfig());
    final runtime = PluginRuntime.fromPlugins([registered]);
    final processors = runtime.responseProcessors(
      runtime.snapshot(),
      runtime.selectForRole(null),
      PluginResponseInputs(ref: ref, voiceRequest: null),
    );
    final tag = StickerRegistry.instance.allTags.first;
    final text = '晚安~ [$tag] [不存在的标签]';
    final result = await runResponseProcessors(processors, text, logTag: 't');
    final legacy = await registered.convertStickerTags(text);

    // The registry picks one sticker per tag at random; compare everything
    // else and check the pick belongs to the tag.
    expect(result.processedText, legacy.processedText);
    final event = result.events.single;
    expect(event.type, 'sticker_convert');
    expect(event.data['tag'], legacy.events.single.data['tag']);
    expect(
      StickerRegistry.instance.getAllByTag(tag).map((s) => s.id),
      contains(event.data['stickerId']),
    );
  });
}

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
import 'package:aicove_flutter/src/features/stickers/sticker_pack_grants.dart';
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
    StickerRegistry.instance.replaceStickers(const [
      Sticker(
        id: 'sticker-night',
        packId: 'pack',
        path: '/stickers/night.png',
        tags: ['晚安'],
      ),
    ]);
  });
  tearDown(() {
    StickerRegistry.instance.replaceStickers(const []);
    container.dispose();
  });

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
    final text = '晚安~ <sticker tag="$tag"/> <sticker tag="不存在的标签"/>';
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

  group('role pack grants', () {
    setUp(() {
      StickerRegistry.instance.replaceStickers(const [
        Sticker(id: 'cat-night', packId: 'cat', path: '/c.png', tags: ['晚安']),
        Sticker(id: 'cat-hug', packId: 'cat', path: '/h.png', tags: ['抱抱']),
        Sticker(id: 'dog-night', packId: 'dog', path: '/d.png', tags: ['晚安']),
      ]);
    });

    final catOnly = {'sticker', StickerPackGrants.pluginIdOf('cat')};
    final dogOnly = {'sticker', StickerPackGrants.pluginIdOf('dog')};

    test('the prompt lists only tags from granted packs', () async {
      const template = '{tags}';
      final plugin =
          StickerPlugin(const StickerConfig(systemPromptTemplate: template));
      expect(await plugin.buildSystemPrompt(rolePluginIds: dogOnly), '晚安');
      expect(await plugin.buildSystemPrompt(rolePluginIds: catOnly), '抱抱、晚安');
      expect(await plugin.buildSystemPrompt(), '抱抱、晚安');
    });

    test('replies pick stickers only from granted packs', () async {
      final registered = StickerPlugin(const StickerConfig());
      final runtime = PluginRuntime.fromPlugins([registered]);
      Future<Set<Object?>> picks(Set<String>? rolePluginIds) async {
        final processors = runtime.responseProcessors(
          runtime.snapshot(),
          runtime.selectForRole(rolePluginIds),
          PluginResponseInputs(
            ref: ref,
            voiceRequest: null,
            rolePluginIds: rolePluginIds,
          ),
        );
        final ids = <Object?>{};
        for (var i = 0; i < 30; i++) {
          final result = await runResponseProcessors(
            processors,
            '<sticker tag="晚安"/> <sticker tag="抱抱"/>',
            logTag: 't',
          );
          ids.addAll(result.events.map((e) => e.data['stickerId']));
        }
        return ids;
      }

      expect(await picks(dogOnly), {'dog-night'});
      expect(await picks(catOnly), {'cat-night', 'cat-hug'});
    });

    test('grants of packs missing on this device fall back to all packs',
        () async {
      final plugin =
          StickerPlugin(const StickerConfig(systemPromptTemplate: '{tags}'));
      expect(
        await plugin.buildSystemPrompt(
          rolePluginIds: {StickerPackGrants.pluginIdOf('elsewhere')},
        ),
        '抱抱、晚安',
      );
    });
  });
}

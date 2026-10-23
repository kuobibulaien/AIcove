import 'package:aicove_flutter/src/core/services/system_reminder_service.dart';
import 'package:aicove_flutter/src/features/agent_plugins/aicove_plugin.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_request_context.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_request_scope.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/plugin_prompts.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_request.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_response.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_runtime.dart';
import 'package:aicove_flutter/src/features/plugins/trigger/trigger_config.dart';
import 'package:aicove_flutter/src/features/plugins/trigger/trigger_plugin.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _refProvider = Provider<Ref>((ref) => ref);

void main() {
  test('offers the reminder tools and cleans legacy tags in replies',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final ref = container.read(_refProvider);
    final plugin = TriggerPlugin(const TriggerConfig(enabled: true), ref);
    final runtime = PluginRuntime.fromPlugins([plugin]);

    expect(runtime.plugin('trigger')!.capabilities,
        {AppCapability.request, AppCapability.responses});
    final scope = runtime
        .requestScopes(
          runtime.snapshot(),
          runtime.selectForRole(null),
          PluginRequestInputs(
            ref: ref,
            settings: mapUiModelsToAppSettings(const {}),
            imageConfig: const ImageConfig(),
            voiceRequest: VoiceRequest(ownerId: 'role'),
            pluginPrompts: const PluginPrompts(),
            history: const [],
            previousUserMessageTime: null,
            useFastImageRoute: false,
            useStableImageRoute: true,
            supportsToolCalling: true,
            reminders: const SystemReminderService(),
          ),
        )
        .single;
    expect(scope.tools().map((t) => t.name),
        plugin.getTools().map((t) => t.name));
    expect(scope.tools(), hasLength(4));
    // Reminders go through native tool calls; no prompt is injected.
    expect(
      await scope.prompt(const PluginRequestContext(
        userMessage: '明天八点提醒我',
        supportsToolCalling: true,
      )),
      isNull,
    );

    const text = '好的<create_trigger time="10:00" title="喝水">';
    final result = await runResponseProcessors(
      runtime.responseProcessors(
        runtime.snapshot(),
        runtime.selectForRole(null),
        PluginResponseInputs(ref: ref, voiceRequest: null),
      ),
      text,
      logTag: 't',
    );
    expect(result.processedText,
        (await plugin.handleLegacyTriggerTags(text)).processedText);
    expect(result.processedText, isNot(contains('create_trigger')));
  });
}

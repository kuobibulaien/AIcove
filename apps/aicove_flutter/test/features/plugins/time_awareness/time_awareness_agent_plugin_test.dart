import 'package:aicove_flutter/src/core/services/system_reminder_service.dart';
import 'package:aicove_flutter/src/features/agent_plugins/aicove_plugin.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_request_context.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_request_scope.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_runtime.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/plugin_prompts.dart';
import 'package:aicove_flutter/src/features/plugins/time_awareness/time_awareness_config.dart';
import 'package:aicove_flutter/src/features/plugins/time_awareness/time_awareness_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/time_awareness/time_awareness_role_options.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_request.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _refProvider = Provider<Ref>((ref) => ref);

void main() {
  late ProviderContainer container;
  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  PluginRequestInputs inputs({
    PluginPrompts prompts = const PluginPrompts(),
    DateTime? previous,
    Set<String>? rolePluginIds,
  }) =>
      PluginRequestInputs(
        ref: container.read(_refProvider),
        settings: mapUiModelsToAppSettings(const {}),
        imageConfig: const ImageConfig(),
        voiceRequest: VoiceRequest(ownerId: 'role'),
        pluginPrompts: prompts,
        history: const [],
        rolePluginIds: rolePluginIds,
        previousUserMessageTime: previous,
        useFastImageRoute: false,
        useStableImageRoute: true,
        supportsToolCalling: true,
        reminders: const SystemReminderService(),
      );

  PluginRequestScope scopeOf(TimeAwarenessPlugin plugin, PluginRequestInputs i) {
    final runtime = PluginRuntime.fromPlugins([plugin]);
    return runtime
        .requestScopes(runtime.snapshot(), runtime.selectForRole(null), i)
        .single;
  }

  test('current time follows each role, independent of the global snapshot', () {
    final plugin = TimeAwarenessPlugin(
      TimeAwarenessConfig(includeCurrentTime: false),
    );
    final now = DateTime(2026, 10, 30, 12, 30);
    final previous = DateTime(2026, 10, 29, 18);
    for (final ids in <Set<String>?>[
      { 'time_awareness', TimeAwarenessRoleOptions.noCurrentTimeId },
      { 'time_awareness' },
      null,
    ]) {
      final scope = scopeOf(plugin, inputs(previous: previous, rolePluginIds: ids));
      final content = scope.reminders(now).single.content;
      final includeCurrent = TimeAwarenessRoleOptions.currentTime(ids);
      expect(content.contains('2026-10-30 12:30'), includeCurrent);
      expect(content.contains('当前时间:'), includeCurrent);
      expect(content, contains('用户上一次发消息的时间为2026-10-29 18:00'));
      expect(scope.timeContextTrace!.config['includeCurrentTime'], includeCurrent);
    }
    expect(plugin.config.includeCurrentTime, isFalse);
  });

  test('installs natively and declares only the request capability', () {
    final plugin = TimeAwarenessPlugin(TimeAwarenessConfig());
    final runtime = PluginRuntime.fromPlugins([plugin]);
    expect(runtime.plugin('time_awareness')!.capabilities,
        {AppCapability.request});
  });

  test('prompt, reminder and trace match the plugin on the request snapshot',
      () async {
    const template = '现在是 {datetime}';
    final prompts = const PluginPrompts()
        .withText(PluginPromptSlot.currentTime, template);
    final previous = DateTime(2026, 3, 23, 9);
    final now = DateTime(2026, 3, 23, 10, 30);
    final scope = scopeOf(
      TimeAwarenessPlugin(TimeAwarenessConfig()),
      inputs(prompts: prompts, previous: previous),
    );
    final expected = TimeAwarenessPlugin(
      TimeAwarenessConfig().copyWith(currentTimePromptTemplate: template),
    );

    expect(scope.active, isTrue);
    expect(
      await scope.prompt(const PluginRequestContext(
        userMessage: 'hi',
        supportsToolCalling: true,
      )),
      expected.buildTagSemanticsPrompt(),
    );
    final reminder = scope.reminders(now).single;
    expect(reminder.order, 10);
    expect(
      reminder.content,
      const SystemReminderService().buildReminderContent(
        expected.buildSystemReminderPayload(
          currentTime: now,
          previousUserMessageTime: previous,
        )!,
      ),
    );
    expect(reminder.content, contains('现在是'));
    expect(scope.tools(), isEmpty);
    expect(scope.timeContextTrace!.config['currentTimePromptTemplate'],
        template);
  });
}

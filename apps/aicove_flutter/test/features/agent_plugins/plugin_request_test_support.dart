import 'package:aicove_flutter/src/core/services/system_reminder_service.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_request_scope.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/plugin_prompts.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_request.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _refProvider = Provider<Ref>((ref) => ref);

/// A real provider ref, kept alive until the current test's teardown.
PluginRequestInputs createPluginRequestInputs({
  bool packageExecutable = true,
  String? conversationId,
}) {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return PluginRequestInputs(
    ref: container.read(_refProvider),
    settings: mapUiModelsToAppSettings(const {}),
    imageConfig: const ImageConfig(),
    voiceRequest: VoiceRequest(ownerId: conversationId ?? 'test'),
    pluginPrompts: const PluginPrompts(),
    conversationId: conversationId,
    history: const [],
    previousUserMessageTime: null,
    useFastImageRoute: false,
    useStableImageRoute: false,
    supportsToolCalling: true,
    reminders: const SystemReminderService(),
    packageExecutable: packageExecutable,
  );
}

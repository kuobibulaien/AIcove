import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/features/observability/trace_models.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_response.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_runtime.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_manager.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_service.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_request.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_backend_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';

class _Runner extends ChatSendApiRunner {
  @override
  Future<ApiCallResult> executeApiCall(
      {required ApiConfig config,
      required String sessionId,
      required String? userText,
      required List<PluginResponseProcessor> responseProcessors,
      List<AITool>? availableTools,
      String? turnId,
      TraceLogger? trace,
      int maxRounds = 5,
      void Function(String)? onToolExecuting,
      bool enableStreaming = false,
      void Function(String)? onStreamTextDelta,
      void Function()? onStreamTextReset,
      void Function()? onStreamToolCallObserved,
      void Function()? onStreamingFallback,
      TraceContext? traceContext}) async {
    onStreamTextDelta?.call('<tts>测试语音</tts>');
    final result = await runResponseProcessors(
        responseProcessors, '<tts>测试语音</tts>',
        logTag: 'test');
    return ApiCallResult(
        replyText: '<tts>测试语音</tts>',
        processedText: result.processedText,
        pluginEvents: result.events,
        toolResults: const []);
  }
}

void main() {
  test(
      'real backend propagates frozen request into streaming callbacks and post-stream events',
      () async {
    final request = VoiceRequest(
        ownerId: 'role-a',
        service: TtsService(
            config: TtsConfig(enabled: true, voiceFrequency: 40),
            requestUrl: 'https://a.invalid',
            model: 'speech'));
    final backendProvider = Provider((ref) => ChatSendBackendService(ref,
        apiRunner: _Runner(),
        readImageAsBase64: (_) async => null,
        shouldUseNonVisionImageFlow: ({required settings, required modelRef}) =>
            false,
        resolveTimeAwarenessPreviousUserMessageTime: (_) => null));
    // No globally enabled TTS plugin at execution: the in-progress request
    // must still use the reply processors fixed at prepare rather than the
    // now changed global registry.
    final container = ProviderContainer(
        overrides: [pluginManagerProvider.overrideWithValue(PluginManager())]);
    addTearDown(container.dispose);
    final refProvider = Provider<Ref>((ref) => ref);
    final prepared =
        PluginRuntime.fromPlugins([TtsPlugin(TtsConfig(enabled: true))]);
    final config = ApiConfig(
        settings: mapUiModelsToAppSettings({}),
        modelFullId: 'model',
        providerApiBase: 'https://example.invalid',
        customConfig: const {},
        messages: const [],
        voiceRequest: request,
        responseProcessors: prepared.responseProcessors(
            prepared.snapshot(),
            prepared.selectForRole(null),
            PluginResponseInputs(
                ref: container.read(refProvider), voiceRequest: request)));
    final captured = Completer<VoiceRequest?>();
    final backend = container.read(backendProvider);
    final result = await backend.executeApiCall(
        config: config,
        sessionId: 'role-a',
        userText: 'hello',
        enableStreaming: true,
        onStreamTextDelta: (_) {
          Timer(Duration.zero, () => captured.complete(VoiceRequest.current));
        });
    expect(await captured.future, same(request));
    expect(VoiceRequest.forEvents(result.pluginEvents), same(request));
    expect(VoiceRequest.current, isNull);
    await expectLater(
        backend.executeApiCall(
            config: config, sessionId: 'role-b', userText: 'wrong'),
        throwsStateError);
  });
}

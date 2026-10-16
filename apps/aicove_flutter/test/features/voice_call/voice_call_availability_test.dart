import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_service.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_preset_application.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_request.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/voice_call/providers/voice_call_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Settings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => mapUiModelsToAppSettings({});
}

class _Voices implements VoicePresetApplicationPort {
  _Voices(this.request);
  final VoiceRequest request;

  @override
  Future<VoiceRequest> forRole(Conversation owner) async => request;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

TtsService _fish({String voiceId = 'voice-1', String apiKey = ''}) {
  final preset = VoicePreset(
    id: 'p1',
    name: '温柔女声',
    synthesis: VoiceSynthesisSettings(
      providerId: 'fish_audio',
      modelId: 's2.1-pro-free',
      voiceId: voiceId,
    ),
  );
  return TtsService(
    config: TtsConfig(voicePresets: [preset], selectedVoicePresetId: 'p1'),
    apiKey: apiKey,
    requestUrl: 'https://api.fish.audio',
    requestFormat: 'fish_audio',
  );
}

Future<String?> _reason(VoiceRequest request) async {
  final container = ProviderContainer(
    overrides: [
      appSettingsProvider.overrideWith(_Settings.new),
      voicePresetApplicationProvider.overrideWithValue(_Voices(request)),
    ],
  );
  addTearDown(container.dispose);
  final t = DateTime(2026, 10, 14);
  return container
      .read(voiceCallFactoryProvider)
      .unavailableReason(
        Conversation(
          id: 'nahida',
          title: '纳西妲',
          displayName: '纳西妲',
          createdAt: t,
          updatedAt: t,
        ),
      );
}

void main() {
  test('没有音色预设时说明原因，不往下检查识别', () async {
    expect(
      await _reason(
        VoiceRequest(ownerId: 'nahida', error: '请先绑定音色预设或设置默认预设'),
      ),
      '请先绑定音色预设或设置默认预设',
    );
  });

  test('Fish Audio 渠道 Key 为空时提示去模型设置填写', () async {
    final reason = await _reason(
      VoiceRequest(ownerId: 'nahida', service: _fish()),
    );
    expect(reason, contains('API Key'));
    expect(reason, contains('设置 · 模型'));
  });

  test('音色 ID 为空时单独提示', () async {
    final reason = await _reason(
      VoiceRequest(
        ownerId: 'nahida',
        service: _fish(voiceId: '', apiKey: 'k'),
      ),
    );
    expect(reason, contains('音色 ID'));
  });
}

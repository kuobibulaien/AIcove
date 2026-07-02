import 'tts_synthesis_adapter.dart';

class SiliconFlowTtsSynthesisAdapter extends TtsSynthesisAdapter {
  const SiliconFlowTtsSynthesisAdapter();

  @override
  String get providerId => 'siliconflow';

  @override
  List<String> get requestFormatAliases => const ['siliconflow_indextts'];

  @override
  Duration resolveTimeout(TtsSynthesisContext context) {
    return const Duration(seconds: 30);
  }

  @override
  Uri buildSpeechUri(TtsSynthesisContext context) {
    return TtsSynthesisAdapter.appendSpeechPath(context.rawUrl);
  }

  @override
  Map<String, dynamic> buildRequestBody(TtsSynthesisContext context) {
    final effectiveModel =
        context.model ?? context.config.model ?? 'IndexTeam/IndexTTS-2';
    final preset = context.config.selectedVoicePreset;
    final body = <String, dynamic>{
      'model': effectiveModel,
      'input': context.text,
      'response_format': 'mp3',
    };

    final speed = context.config.speed;
    if (speed != null && speed != 1.0) {
      body['speed'] = speed;
    }

    final siliconFlowVoiceUri = preset
            ?.resolveBinding(
              providerId: context.config.selectedProviderId ?? providerId,
              adapterId: providerId,
              modelId: effectiveModel,
            )
            ?.remoteVoiceId ??
        preset?.siliconFlowVoiceUri;
    if (_hasText(siliconFlowVoiceUri)) {
      body['voice'] = siliconFlowVoiceUri;
      return body;
    }

    final configVoice = context.config.voice;
    if (_hasText(configVoice)) {
      if (configVoice!.contains(':') || configVoice.startsWith('speech:')) {
        body['voice'] = configVoice;
      } else {
        body['voice'] = '$effectiveModel:$configVoice';
      }
      return body;
    }

    final promptAudioUrl = context.config.effectivePromptAudioUrl?.trim();
    final promptText = context.config.effectivePromptText?.trim();
    if (_hasText(promptAudioUrl)) {
      body['voice'] = '';
      body['references'] = [
        {
          'audio': promptAudioUrl,
          if (_hasText(promptText)) 'text': promptText,
        }
      ];
      return body;
    }

    body['voice'] = 'FunAudioLLM/CosyVoice2-0.5B:alex';
    return body;
  }

  bool _hasText(String? value) {
    return value != null && value.trim().isNotEmpty;
  }
}

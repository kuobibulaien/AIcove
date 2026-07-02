import 'tts_synthesis_adapter.dart';

class TtsSynthesisFormats {
  static const String openAi = 'openai_tts';
  static const String siliconFlowIndexTts = 'siliconflow_indextts';
  static const String minimax = 'minimax';
  static const String minimaxTts = 'minimax_tts';

  const TtsSynthesisFormats._();
}

class MinimaxTtsSynthesisAdapter extends TtsSynthesisAdapter {
  static const String _defaultVoiceId = 'male-qn-qingse';

  const MinimaxTtsSynthesisAdapter();

  @override
  String get providerId => 'minimax';

  @override
  List<String> get requestFormatAliases => const <String>[
        TtsSynthesisFormats.minimax,
        TtsSynthesisFormats.minimaxTts,
      ];

  @override
  bool supports(TtsSynthesisContext context) {
    final normalizedProviderId =
        TtsSynthesisAdapter.normalizeIdentifier(context.providerId);
    if (normalizedProviderId == providerId) {
      return true;
    }

    final normalizedFormat = TtsSynthesisAdapter.normalizeIdentifier(
        context.normalizedRequestFormat);
    return requestFormatAliases.any(
      (alias) =>
          TtsSynthesisAdapter.normalizeIdentifier(alias) == normalizedFormat,
    );
  }

  @override
  Duration resolveTimeout(TtsSynthesisContext context) {
    return const Duration(seconds: 60);
  }

  @override
  Uri buildSpeechUri(TtsSynthesisContext context) {
    final uri = Uri.parse(context.rawUrl);
    final segments = uri.pathSegments.where((segment) => segment.isNotEmpty);
    final normalizedSegments = <String>[...segments];

    if (normalizedSegments.isEmpty) {
      normalizedSegments.addAll(const <String>['v1', 't2a_v2']);
    } else if (normalizedSegments.last != 't2a_v2') {
      if (normalizedSegments.last == 'v1') {
        normalizedSegments.add('t2a_v2');
      } else {
        normalizedSegments.addAll(
          normalizedSegments.contains('v1')
              ? const <String>['t2a_v2']
              : const <String>['v1', 't2a_v2'],
        );
      }
    }

    return Uri(
      scheme: uri.scheme,
      userInfo: uri.userInfo,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      pathSegments: normalizedSegments,
    );
  }

  @override
  Map<String, dynamic> buildRequestBody(TtsSynthesisContext context) {
    final voiceId = _resolveVoiceId(context);
    final speed = context.config.speed ?? 1.0;

    return <String, dynamic>{
      'model': context.model ?? context.config.model ?? 'speech-2.8-hd',
      'text': context.text,
      'stream': false,
      'voice_setting': <String, dynamic>{
        'voice_id': voiceId,
        'speed': speed,
        'vol': 1,
        'pitch': 0,
      },
      'audio_setting': const <String, dynamic>{
        'sample_rate': 32000,
        'bitrate': 128000,
        'format': 'mp3',
        'channel': 1,
      },
      'subtitle_enable': false,
      'output_format': 'hex',
    };
  }

  String _resolveVoiceId(TtsSynthesisContext context) {
    final presetVoiceId = context.config.selectedVoicePreset
        ?.resolveBinding(
          providerId: context.config.selectedProviderId ?? providerId,
          adapterId: providerId,
          modelId: context.model ?? context.config.model,
        )
        ?.remoteVoiceId
        .trim();
    if (presetVoiceId != null && presetVoiceId.isNotEmpty) {
      return presetVoiceId;
    }

    final configVoice = context.config.voice?.trim();
    if (configVoice != null && configVoice.isNotEmpty) {
      return configVoice;
    }

    return _defaultVoiceId;
  }
}

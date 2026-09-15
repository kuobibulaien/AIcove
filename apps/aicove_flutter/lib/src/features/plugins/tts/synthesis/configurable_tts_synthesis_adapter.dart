library;

import 'tts_synthesis_adapter.dart';

/// 通用可配置 REST TTS 合成适配器
///
/// 适用于所有标准 HTTP POST 请求并返回二进制音频流（如 MP3、WAV）的 TTS 供应商。
/// 支持零代码扩展新渠道：在 customConfig 中配置路径、Header 与 Body 映射模板即可生效。
/// 同时内置了主流标准服务商（如 Fish Audio）的预置映射。
class ConfigurableTtsSynthesisAdapter extends TtsSynthesisAdapter {
  static const String formatFishAudio = 'fish_audio';
  static const String formatFishAudioAlias = 'fishaudio';
  static const String formatCustomRest = 'custom_rest';
  static const String formatConfigurableRest = 'configurable_rest';
  static const String formatTemplate = 'template';

  static const Map<String, dynamic> _fishAudioPreset = {
    'path': '/tts',
    'headers': {'model': '{model}'},
    'body': {'text': '{text}', 'reference_id': '{voice}', 'format': 'mp3'},
  };

  const ConfigurableTtsSynthesisAdapter();

  @override
  String get providerId => 'configurable_rest';

  @override
  List<String> get requestFormatAliases => const [
    formatFishAudio,
    formatFishAudioAlias,
    formatCustomRest,
    formatConfigurableRest,
    formatTemplate,
  ];

  @override
  bool supports(TtsSynthesisContext context) {
    final normalizedFormat = TtsSynthesisAdapter.normalizeIdentifier(
      context.requestFormat,
    );
    if (requestFormatAliases.any(
      (alias) =>
          TtsSynthesisAdapter.normalizeIdentifier(alias) == normalizedFormat,
    )) {
      return true;
    }

    final normalizedProvider = TtsSynthesisAdapter.normalizeIdentifier(
      context.providerId,
    );
    if (normalizedProvider == formatFishAudio ||
        normalizedProvider == formatFishAudioAlias) {
      return true;
    }

    if (context.customConfig.containsKey('tts_template') ||
        context.customConfig.containsKey('ttsTemplate')) {
      return true;
    }

    return false;
  }

  @override
  Duration resolveTimeout(TtsSynthesisContext context) {
    return const Duration(seconds: 45);
  }

  @override
  Uri buildSpeechUri(TtsSynthesisContext context) {
    final template = _resolveTemplate(context);
    var pathTemplate = (template['path'] as String?)?.trim();
    if (pathTemplate == null || pathTemplate.isEmpty) {
      pathTemplate = '/audio/speech';
    }

    final voiceId = _resolveVoiceId(context);
    final effectiveModel = context.model ?? context.config.model ?? '';
    pathTemplate = pathTemplate
        .replaceAll('{voice}', voiceId)
        .replaceAll('{model}', effectiveModel);

    final uri = Uri.parse(context.rawUrl);
    final rawPath = uri.path;

    String finalPath;
    if (rawPath.isEmpty || rawPath == '/') {
      finalPath = pathTemplate.startsWith('/')
          ? pathTemplate
          : '/$pathTemplate';
    } else {
      final cleanRawPath = rawPath.endsWith('/')
          ? rawPath.substring(0, rawPath.length - 1)
          : rawPath;
      final cleanSubPath = pathTemplate.startsWith('/')
          ? pathTemplate.substring(1)
          : pathTemplate;

      if (cleanRawPath.endsWith(cleanSubPath)) {
        finalPath = cleanRawPath;
      } else if (cleanRawPath.endsWith('v1') &&
          cleanSubPath.startsWith('v1/')) {
        finalPath = '$cleanRawPath/${cleanSubPath.substring(3)}';
      } else {
        finalPath = '$cleanRawPath/$cleanSubPath';
      }
    }

    return Uri(
      scheme: uri.scheme,
      userInfo: uri.userInfo,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: finalPath,
    );
  }

  @override
  Map<String, String> buildHeaders(TtsSynthesisContext context) {
    final headers = super.buildHeaders(context);
    final template = _resolveTemplate(context);
    final customHeaders = template['headers'];

    if (customHeaders is Map) {
      final voiceId = _resolveVoiceId(context);
      final effectiveModel = context.model ?? context.config.model ?? '';
      final apiKey = context.apiKey?.trim() ?? '';

      for (final entry in customHeaders.entries) {
        final key = entry.key.toString();
        var val = entry.value?.toString() ?? '';
        val = val
            .replaceAll('{model}', effectiveModel)
            .replaceAll('{voice}', voiceId)
            .replaceAll('{apiKey}', apiKey);
        headers[key] = val;
      }
    }

    return headers;
  }

  @override
  Map<String, dynamic> buildRequestBody(TtsSynthesisContext context) {
    final template = _resolveTemplate(context);
    final bodyTemplate = template['body'];
    final voiceId = _resolveVoiceId(context);
    final effectiveModel = context.model ?? context.config.model ?? '';
    final speed = context.config.speed ?? 1.0;

    if (bodyTemplate is Map) {
      return _replacePlaceholdersInMap(
        Map<String, dynamic>.from(bodyTemplate),
        text: context.text,
        voice: voiceId,
        model: effectiveModel,
        speed: speed,
      );
    }

    return {
      'model': effectiveModel,
      'input': context.text,
      'voice': voiceId,
      'response_format': 'mp3',
      if (speed != 1.0) 'speed': speed,
    };
  }

  String _resolveVoiceId(TtsSynthesisContext context) {
    final preset = context.config.selectedVoicePreset;
    final bindingVoiceId = preset
        ?.resolveBinding(
          providerId: context.providerId ?? '',
          adapterId: context.providerId ?? '',
          modelId: context.model ?? context.config.model,
        )
        ?.remoteVoiceId
        .trim();
    if (bindingVoiceId != null && bindingVoiceId.isNotEmpty) {
      return bindingVoiceId;
    }
    final configVoice = context.config.voice?.trim();
    if (configVoice != null && configVoice.isNotEmpty) {
      return configVoice;
    }
    return preset?.id ?? '';
  }

  Map<String, dynamic> _resolveTemplate(TtsSynthesisContext context) {
    final custom =
        context.customConfig['tts_template'] ??
        context.customConfig['ttsTemplate'];
    if (custom is Map<String, dynamic>) {
      return custom;
    }
    final format = TtsSynthesisAdapter.normalizeIdentifier(
      context.requestFormat,
    );
    final provider = TtsSynthesisAdapter.normalizeIdentifier(
      context.providerId,
    );
    if (format == formatFishAudio ||
        format == formatFishAudioAlias ||
        provider == formatFishAudio ||
        provider == formatFishAudioAlias) {
      return _fishAudioPreset;
    }
    return const {};
  }

  Map<String, dynamic> _replacePlaceholdersInMap(
    Map<String, dynamic> source, {
    required String text,
    required String voice,
    required String model,
    required double speed,
  }) {
    final result = <String, dynamic>{};
    for (final entry in source.entries) {
      result[entry.key] = _replacePlaceholderValue(
        entry.value,
        text: text,
        voice: voice,
        model: model,
        speed: speed,
      );
    }
    return result;
  }

  dynamic _replacePlaceholderValue(
    dynamic value, {
    required String text,
    required String voice,
    required String model,
    required double speed,
  }) {
    if (value is String) {
      if (value == '{speed}') return speed;
      return value
          .replaceAll('{text}', text)
          .replaceAll('{voice}', voice)
          .replaceAll('{model}', model)
          .replaceAll('{speed}', speed.toString())
          .replaceAll('{format}', 'mp3');
    } else if (value is Map) {
      return _replacePlaceholdersInMap(
        Map<String, dynamic>.from(value),
        text: text,
        voice: voice,
        model: model,
        speed: speed,
      );
    } else if (value is List) {
      return value
          .map(
            (item) => _replacePlaceholderValue(
              item,
              text: text,
              voice: voice,
              model: model,
              speed: speed,
            ),
          )
          .toList();
    }
    return value;
  }
}

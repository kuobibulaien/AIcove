import '../tts_config.dart';

class TtsSynthesisContext {
  const TtsSynthesisContext({
    required this.config,
    required this.text,
    required this.rawUrl,
    this.providerId,
    this.requestFormat = 'openai_tts',
    this.model,
    this.apiKey,
  });

  final TtsConfig config;
  final String text;
  final String rawUrl;
  final String? providerId;
  final String requestFormat;
  final String? model;
  final String? apiKey;

  String get normalizedRequestFormat =>
      TtsSynthesisAdapter.normalizeIdentifier(requestFormat) ?? 'openai_tts';
}

abstract class TtsSynthesisAdapter {
  const TtsSynthesisAdapter();

  String get providerId;

  List<String> get requestFormatAliases;

  bool supports(TtsSynthesisContext context) {
    final normalizedFormat =
        normalizeIdentifier(context.normalizedRequestFormat) ?? 'openai_tts';
    return requestFormatAliases.any(
      (alias) => normalizeIdentifier(alias) == normalizedFormat,
    );
  }

  Duration resolveTimeout(TtsSynthesisContext context);

  Uri buildSpeechUri(TtsSynthesisContext context);

  Map<String, dynamic> buildRequestBody(TtsSynthesisContext context);

  Map<String, String> buildHeaders(TtsSynthesisContext context) {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'X-Failover-Enabled': 'true',
    };

    final key = context.apiKey?.trim();
    if (key != null && key.isNotEmpty) {
      headers['Authorization'] = 'Bearer $key';
    }

    return headers;
  }

  static String? normalizeIdentifier(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed.toLowerCase();
  }

  static Uri appendSpeechPath(String rawUrl) {
    final uri = Uri.parse(rawUrl);
    const speechPath = '/audio/speech';
    final path = uri.path;

    if (path.contains(speechPath)) {
      return _withoutQuery(uri);
    }

    final newPath = switch (path) {
      '' || '/' => speechPath,
      _ when path.endsWith('/') => '$path${speechPath.substring(1)}',
      _ => '$path$speechPath',
    };

    return _withoutQuery(
      uri,
      path: newPath,
    );
  }

  static Uri _withoutQuery(Uri uri, {String? path}) {
    return Uri(
      scheme: uri.scheme,
      userInfo: uri.userInfo,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: path ?? uri.path,
    );
  }
}

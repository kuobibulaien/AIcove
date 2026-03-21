import 'tts_synthesis_adapter.dart';

class OpenAiCompatibleTtsSynthesisAdapter extends TtsSynthesisAdapter {
  const OpenAiCompatibleTtsSynthesisAdapter();

  @override
  String get providerId => 'openai_compatible';

  @override
  List<String> get requestFormatAliases => const ['openai_tts'];

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
    final body = <String, dynamic>{
      'model': context.model ?? context.config.model ?? 'tts-1',
      'input': context.text,
      'voice': context.config.voice ?? 'alloy',
    };

    final speed = context.config.speed;
    if (speed != null && speed != 1.0) {
      body['speed'] = speed;
    }

    return body;
  }
}

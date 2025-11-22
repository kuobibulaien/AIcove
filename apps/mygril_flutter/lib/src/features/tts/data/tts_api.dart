import '../../../core/api_client.dart';

class TtsApi {
  final ApiClient _api;
  TtsApi([ApiClient? api]) : _api = api ?? ApiClient(timeout: const Duration(seconds: 20));

  Future<TtsResponse> synthesize({required String text, String? voiceId, String? emotion}) async {
    final body = {
      'text': text,
      if (voiceId != null) 'voice_id': voiceId,
      if (emotion != null) 'emotion': emotion,
    };
    final data = await _api.postJson('/api/tts', body);
    return TtsResponse(
      audioUrl: (data['audio_url'] as String?) ?? '',
      cached: (data['cached'] as bool?) ?? false,
    );
  }
}

class TtsResponse {
  final String audioUrl;
  final bool cached;
  const TtsResponse({required this.audioUrl, required this.cached});
}

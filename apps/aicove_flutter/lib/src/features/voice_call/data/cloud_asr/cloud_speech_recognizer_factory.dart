import '../../../settings/settings_models.dart';
import '../../domain/asr_request_format.dart';
import '../../domain/speech_recognizer_port.dart';
import '../aliyun_realtime_speech_recognizer.dart';
import 'deepgram_speech_recognizer.dart';
import 'elevenlabs_speech_recognizer.dart';
import 'openai_realtime_speech_recognizer.dart';
import 'tencent_speech_recognizer.dart';
import 'volcengine_speech_recognizer.dart';
import 'websocket_speech_recognizer.dart';
import 'xfyun_speech_recognizer.dart';

/// 云端识别器缺配置（没写格式、缺凭证）时抛出，消息直接给用户看。
class CloudRecognizerConfigError implements Exception {
  const CloudRecognizerConfigError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 说完一句后服务端判停的静音时长。300 ms 会在句中逗号停顿处误切（阿里云实测）。
const kCloudEndOfTurnSilenceMs = 500;

/// 渠道 + 模型 → 识别器。只按渠道的 `asrRequestFormat` 路由（ADR0082）。
SpeechRecognizerPort createCloudSpeechRecognizer(
  ProviderAuth provider,
  String model, {
  WebSocketConnector? connect,
}) {
  final format = AsrRequestFormat.ofConfig(provider.customConfig);
  if (format == null) {
    throw CloudRecognizerConfigError(
      '渠道「${provider.displayName ?? provider.id}」没有设置语音识别格式',
    );
  }
  String required(String value, String label) {
    if (value.trim().isEmpty) {
      throw CloudRecognizerConfigError(
        '渠道「${provider.displayName ?? provider.id}」缺少 $label',
      );
    }
    return value.trim();
  }

  final apiKey = required(
    provider.apiKeys.firstOrNull ?? '',
    format.apiKeyLabel,
  );
  String extra(String key) =>
      provider.customConfig[key]?.toString().trim() ?? '';
  final endpoint = format.endpointFor(provider.apiBaseUrl);
  const silence = kCloudEndOfTurnSilenceMs;

  return switch (format) {
    AsrRequestFormat.aliyun
        when AsrRequestFormat.isAliyunQwenRealtimeModel(model) =>
      AliyunQwenRealtimeSpeechRecognizer(
        apiKey: apiKey,
        model: model,
        endpoint: endpoint,
        endOfTurnSilenceMs: silence,
        connect: connect,
      ),
    AsrRequestFormat.aliyun => AliyunRealtimeSpeechRecognizer(
      apiKey: apiKey,
      model: model,
      endpoint: endpoint.toString(),
      endOfTurnSilenceMs: silence,
      connect: connect,
    ),
    AsrRequestFormat.volcengine => VolcengineSpeechRecognizer(
      apiKey: apiKey,
      appId: extra('asr_app_id'),
      resourceId: model,
      endpoint: endpoint,
      endOfTurnSilenceMs: silence,
      connect: connect,
    ),
    AsrRequestFormat.tencent => TencentSpeechRecognizer(
      appId: required(extra('asr_app_id'), 'AppID'),
      secretId: required(extra('asr_secret_id'), 'SecretId'),
      secretKey: apiKey,
      engineModelType: model,
      endpoint: endpoint,
      endOfTurnSilenceMs: silence,
      connect: connect,
    ),
    AsrRequestFormat.xfyun => XfyunSpeechRecognizer(
      appId: required(extra('asr_app_id'), 'APPID'),
      apiKey: apiKey,
      endpoint: endpoint,
      connect: connect,
    ),
    AsrRequestFormat.openai => OpenAiRealtimeSpeechRecognizer(
      apiKey: apiKey,
      model: model,
      endpoint: endpoint,
      endOfTurnSilenceMs: silence,
      connect: connect,
    ),
    AsrRequestFormat.deepgram => DeepgramSpeechRecognizer(
      apiKey: apiKey,
      model: model,
      language: extra('asr_language'),
      endpoint: endpoint,
      endOfTurnSilenceMs: silence,
      connect: connect,
    ),
    AsrRequestFormat.elevenlabs => ElevenLabsSpeechRecognizer(
      apiKey: apiKey,
      model: model,
      endpoint: endpoint,
      endOfTurnSilenceMs: silence,
      connect: connect,
    ),
    _ => throw CloudRecognizerConfigError('不支持的语音识别格式：${format.label}'),
  };
}

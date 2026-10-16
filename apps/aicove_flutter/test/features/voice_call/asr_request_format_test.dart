import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/settings/data/support/ui_models_store_support.dart';
import 'package:aicove_flutter/src/features/voice_call/domain/asr_request_format.dart';
import 'package:aicove_flutter/src/features/voice_call/providers/voice_call_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _provider(
  String id,
  String url,
  List<String> models, {
  List<String> capabilities = const <String>['chat'],
  Map<String, dynamic>? customConfig,
  List<String> keys = const <String>['k'],
}) => <String, dynamic>{
  'id': id,
  'apiKeys': keys,
  'apiBaseUrl': url,
  'enabled': true,
  'models': models,
  'visible_models': models,
  'capabilities': capabilities,
  if (customConfig != null) 'custom_config': customConfig,
};

AppSettings _settings(List<Map<String, dynamic>> providers) =>
    mapUiModelsToAppSettings(
      normalizeUiModelsStoreData(<String, dynamic>{'providers': providers}),
    );

class _Settings extends AppSettingsNotifier {
  _Settings(this.value);
  final AppSettings value;

  @override
  Future<AppSettings> build() async => value;
}

void main() {
  group('registry', () {
    test(
      'fills a missing format from the host only for providers with ASR models',
      () {
        String? norm(String url, {bool asr = true}) =>
            AsrRequestFormat.normalizeStored(
              rawFormat: null,
              apiBaseUrl: url,
              hasSpeechRecognitionModels: asr,
            );
        expect(
          norm('https://dashscope.aliyuncs.com/compatible-mode/v1'),
          'aliyun_asr',
        );
        expect(
          norm('wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async'),
          'volcengine_asr',
        );
        expect(norm('wss://asr.cloud.tencent.com/asr/v2'), 'tencent_asr');
        expect(norm('wss://rtasr.xfyun.cn/v1/ws'), 'xfyun_rtasr');
        expect(norm('https://api.groq.com/openai/v1'), 'openai_realtime_asr');
        expect(norm('https://api.deepseek.com', asr: false), isNull);
        expect(
          AsrRequestFormat.normalizeStored(
            rawFormat: 'deepgram',
            apiBaseUrl: 'https://dashscope.aliyuncs.com',
            hasSpeechRecognitionModels: true,
          ),
          'deepgram',
        );
      },
    );

    test('derives websocket endpoints from http base URLs', () {
      expect(
        AsrRequestFormat.aliyun
            .endpointFor(
              'https://dashscope-intl.aliyuncs.com/compatible-mode/v1',
            )
            .toString(),
        'wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference',
      );
      expect(
        AsrRequestFormat.openai
            .endpointFor('https://api.openai.com/v1/')
            .toString(),
        'wss://api.openai.com/v1/realtime',
      );
      expect(
        AsrRequestFormat.tencent
            .endpointFor('ws://127.0.0.1:9000/asr/v2')
            .toString(),
        'ws://127.0.0.1:9000/asr/v2',
      );
      expect(
        AsrRequestFormat.deepgram
            .endpointFor('https://whatever.example')
            .toString(),
        AsrRequestFormat.deepgram.defaultEndpoint,
      );
    });
  });

  group('store normalization', () {
    test(
      'the old built-in aliyun provider gains realtime ASR models exactly once',
      () {
        var data = normalizeUiModelsStoreData(<String, dynamic>{
          'providers': [
            _provider(
              'aliyun',
              'https://dashscope.aliyuncs.com/compatible-mode/v1',
              const ['cosyvoice-v3-plus'],
              capabilities: const ['tts'],
            ),
          ],
        });
        var settings = mapUiModelsToAppSettings(data);
        var aliyun = settings.getProvider('aliyun')!;
        expect(aliyun.models, containsAll(kAliyunSeededAsrModels));
        expect(aliyun.customConfig[AsrRequestFormat.configKey], 'aliyun_asr');
        expect(aliyun.customConfig['requestFormat'], 'aliyun');
        expect(
          settings.getProviderModelsByType('aliyun', type: ModelType.stt),
          containsAll(kAliyunSeededAsrModels),
        );
        expect(
          settings.getProviderModelsByType('aliyun', type: ModelType.tts),
          ['cosyvoice-v3-plus'],
        );

        // 用户删掉识别模型后不会被再加回来。
        final providers = (data['providers'] as List)
            .cast<Map<String, dynamic>>();
        providers.first['models'] = ['cosyvoice-v3-plus'];
        providers.first['visible_models'] = ['cosyvoice-v3-plus'];
        data = normalizeUiModelsStoreData(data);
        settings = mapUiModelsToAppSettings(data);
        aliyun = settings.getProvider('aliyun')!;
        expect(aliyun.models, ['cosyvoice-v3-plus']);
      },
    );

    test(
      'ASR-only providers type every untyped model as speech recognition',
      () {
        final settings = _settings([
          _provider(
            'tencent_asr',
            'wss://asr.cloud.tencent.com/asr/v2',
            const ['16k_zh', 'Hy-ASR-3.0-preview'],
            capabilities: const ['stt'],
            customConfig: const {'asrRequestFormat': 'tencent_asr'},
          ),
        ]);
        expect(
          settings.getProviderModelsByType('tencent_asr', type: ModelType.stt),
          ['16k_zh', 'Hy-ASR-3.0-preview'],
        );
        expect(settings.getProvider('tencent_asr')!.capabilities, ['stt']);
      },
    );

    test('OpenAI transcription models are inferred as speech recognition', () {
      expect(ModelType.inferFromModelId('gpt-4o-transcribe'), ModelType.stt);
      expect(ModelType.inferFromModelId('scribe_v2_realtime'), ModelType.stt);
      expect(ModelType.inferFromModelId('fun-asr-realtime'), ModelType.stt);
      expect(ModelType.inferFromModelId('gpt-4o-mini'), ModelType.chat);
    });
  });

  group('recognizer options', () {
    test('lists ASR models of enabled providers and names what is missing', () {
      final settings = _settings([
        _provider(
          'tencent_asr',
          'wss://asr.cloud.tencent.com/asr/v2',
          const ['16k_zh'],
          capabilities: const ['stt'],
          customConfig: const {
            'asrRequestFormat': 'tencent_asr',
            'asr_app_id': '1',
          },
        ),
        _provider(
          'dg',
          'wss://api.deepgram.com/v1/listen',
          const ['nova-3'],
          capabilities: const ['stt'],
          customConfig: const {'asrRequestFormat': 'deepgram'},
          keys: const [],
        ),
        _provider('deepseek', 'https://api.deepseek.com', const [
          'deepseek-chat',
        ]),
      ]);
      final options = cloudRecognizerOptions(settings);
      expect(options.map((o) => o.model), ['16k_zh', 'nova-3']);
      expect(options[0].missing, 'SecretId');
      expect(options[1].missing, 'API Key');
    });

    test('sources round-trip through storage', () {
      for (final source in [
        CallRecognizerSource.auto,
        CallRecognizerSource.local,
        const CallRecognizerSource.cloud('aliyun', 'fun-asr-realtime'),
      ]) {
        expect(CallRecognizerSource.decode(source.encode()), source);
      }
      expect(CallRecognizerSource.decode('garbage'), isNull);
    });

    test(
      'the old 阿里云百炼 choice migrates to the aliyun provider ASR model',
      () async {
        SharedPreferences.setMockInitialValues({
          'aicove.voice_call.recognizer_source.v1': 'aliyun',
        });
        final settings = _settings([
          _provider(
            'aliyun',
            'https://dashscope.aliyuncs.com/compatible-mode/v1',
            const ['cosyvoice-v3-plus'],
            capabilities: const ['tts'],
          ),
        ]);
        final container = ProviderContainer(
          overrides: [
            appSettingsProvider.overrideWith(() => _Settings(settings)),
          ],
        );
        addTearDown(container.dispose);
        final source = await container.read(
          callRecognizerSourceProvider.future,
        );
        expect(source.kind, CallRecognizerKind.cloud);
        expect(source.providerId, 'aliyun');
        expect(kAliyunSeededAsrModels, contains(source.model));
      },
    );
  });
}

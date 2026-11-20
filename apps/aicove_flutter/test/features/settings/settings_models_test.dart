import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/settings/data/support/ui_models_store_support.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

void main() {
  test('WindowsCloseBehavior defaults to asking for unknown values', () {
    expect(WindowsCloseBehavior.fromValue(null), WindowsCloseBehavior.ask);
    expect(WindowsCloseBehavior.fromValue('bogus'), WindowsCloseBehavior.ask);
    expect(WindowsCloseBehavior.fromValue('tray'), WindowsCloseBehavior.tray);
    expect(WindowsCloseBehavior.fromValue('exit'), WindowsCloseBehavior.exit);
  });

  test('claude-fable-5 should infer as chat instead of TTS', () {
    expect(ModelType.inferFromModelId('claude-fable-5'), ModelType.chat);
  });

  test('OpenAI TTS voice ids still infer as TTS when exact', () {
    expect(ModelType.inferFromModelId('fable'), ModelType.tts);
    expect(ModelType.inferFromModelId('openai:fable'), ModelType.tts);
  });

  group('图片生成模型名称推断', () {
    for (final id in [
      'gpt-image-1',
      '_gpt-image-1',
      'vendor_kolors_v1',
      'openai:gpt-image-1',
      'chatgpt-image-latest',
      'Kwai-Kolors/Kolors',
      'doubao-seedream-3-0-t2i',
      'qwen-image',
      'recraft-v3',
      'gemini-2.5-flash-image',
      'gemini:2.5-flash-image',
      'gemini-3-pro-image-preview',
      'imagen-4.0-generate-001',
    ]) {
      test('$id 推断为图像生成', () {
        expect(ModelType.inferFromModelId(id), ModelType.image);
      });
    }
    for (final id in [
      'gpt-4o',
      'gemini-2.5-flash',
      'my-paint-v1',
      'chat-vision',
      'image-chat',
      'my-image-model',
      'qwen-vl-max',
    ]) {
      test('$id 不因支持图片输入或含 image 字样误判为生成', () {
        expect(ModelType.inferFromModelId(id), ModelType.chat);
      });
    }
    test('图片嵌入模型仍为 embedding', () {
      expect(
        ModelType.inferFromModelId('image-embedding-v1'),
        ModelType.embedding,
      );
    });
  });

  group('模型类型统一解析优先级', () {
    test('渠道覆盖优先于裸 ID 覆盖、渠道默认和名称', () {
      expect(
        resolveEffectiveModelType(
          providerId: 'paint',
          rawModelId: 'gpt-image-1',
          modelTypes: const {
            'paint:gpt-image-1': 'chat',
            'gpt-image-1': 'image',
          },
          defaultType: ModelType.tts,
        ),
        ModelType.chat,
      );
    });
    test('空渠道覆盖不阻止裸 ID 覆盖生效', () {
      expect(
        resolveEffectiveModelType(
          providerId: 'paint',
          rawModelId: 'custom-model',
          modelTypes: const {
            'paint:custom-model': '  ',
            'custom-model': 'image',
          },
          defaultType: ModelType.tts,
        ),
        ModelType.image,
      );
    });
    test('没有覆盖时渠道默认优先于名称推断', () {
      expect(
        resolveEffectiveModelType(
          providerId: 'paint',
          rawModelId: 'gpt-4o',
          defaultType: ModelType.image,
        ),
        ModelType.image,
      );
      expect(
        resolveEffectiveModelType(
          providerId: 'voice',
          rawModelId: 'gpt-4o',
          defaultType: ModelType.tts,
        ),
        ModelType.tts,
      );
      expect(
        resolveEffectiveModelType(
          providerId: 'paint',
          rawModelId: 'gpt-image-1',
        ),
        ModelType.image,
      );
    });
    test('缺省通用格式忽略旧 chat 默认类型且保留名称推断', () {
      final defaultType = resolveProviderDefaultModelType(
        providerId: 'paint',
        customConfig: const {'defaultModelType': 'chat'},
      );
      expect(defaultType, isNull);
      expect(
        resolveEffectiveModelType(
          providerId: 'paint',
          rawModelId: 'gpt-image-1',
          defaultType: defaultType,
        ),
        ModelType.image,
      );
    });
    for (final format in ['openai', 'claude', 'gemini']) {
      for (final defaultType in ['chat', 'image', 'tts', 'stt']) {
        test('$format 不将旧 $defaultType 默认类型施加到整个渠道', () {
          expect(
            resolveProviderDefaultModelType(
              providerId: 'custom',
              customConfig: {'requestFormat': format, 'defaultModelType': defaultType},
              capabilities: const ['stt'],
            ),
            isNull,
          );
        });
      }
    }
    test('专用图像、语音和非通用识别渠道保留默认用途', () {
      for (final format in ['comfyui', 'novelai', 'nai']) {
        expect(resolveProviderDefaultModelType(
          providerId: 'custom', customConfig: {'requestFormat': format},
        ), ModelType.image);
      }
      for (final format in ['openai_tts', 'fish_audio', 'aliyun']) {
        expect(resolveProviderDefaultModelType(
          providerId: 'custom', customConfig: {'requestFormat': format},
        ), ModelType.tts);
      }
      expect(resolveProviderDefaultModelType(
        providerId: 'custom', capabilities: const ['stt'],
      ), ModelType.stt);
    });
    test('语音默认仍保留 whisper 的识别类型', () {
      expect(
        resolveEffectiveModelType(
          providerId: 'voice',
          rawModelId: 'whisper-1',
          defaultType: ModelType.tts,
        ),
        ModelType.stt,
      );
    });
  });

  group('inferChatModelCapabilities', () {
    test('every chat model defaults to vision, tools, reasoning and web', () {
      const all = [
        ChatModelCapability.vision,
        ChatModelCapability.tools,
        ChatModelCapability.reasoning,
        ChatModelCapability.web,
      ];
      expect(inferChatModelCapabilities('my-custom-model'), all);
      expect(inferChatModelCapabilities('deepseek-flash'), all);
      expect(inferChatModelCapabilities('sonar-pro'), all);
    });

    test('web capability is parsed and stored values are kept', () {
      expect(ChatModelCapability.fromValue('web'), ChatModelCapability.web);
      expect(
        ChatModelCapability.normalizeValues(<String>['vision', 'web']),
        <String>['vision', 'web'],
      );
    });
  });

  group('ModelConfig.thinkingLevel', () {
    test('json round-trip and isDefault', () {
      const config = ModelConfig(thinkingLevel: ThinkingLevel.xhigh);
      expect(config.isDefault, isFalse);
      expect(config.toJson()['thinking_level'], 'xhigh');
      expect(ModelConfig.fromJson(config.toJson()).thinkingLevel,
          ThinkingLevel.xhigh);
      expect(const ModelConfig().toJson(), isNot(contains('thinking_level')));
    });

    test('invalid stored value normalizes to null', () {
      expect(ModelConfig.fromJson({'thinking_level': 'bogus'}).thinkingLevel,
          isNull);
    });

    test('copyWith clearThinkingLevel', () {
      const config = ModelConfig(thinkingLevel: ThinkingLevel.low);
      expect(config.copyWith(thinkingLevel: ThinkingLevel.high).thinkingLevel,
          ThinkingLevel.high);
      expect(config.copyWith(clearThinkingLevel: true).thinkingLevel, isNull);
      expect(config.copyWith(clearThinkingLevel: true).isDefault, isTrue);
    });
  });

  group('AppSettings glass effect settings', () {
    test('default values are true and 16.0', () {
      final settings = mapUiModelsToAppSettings({});
      expect(settings.glassEffectEnabled, isTrue);
      expect(settings.glassBlurSigma, 16.0);
    });

    test('fresh install store starts on the recommended frosted step', () {
      final settings = mapUiModelsToAppSettings(buildDefaultUiModelsStoreData());
      expect(settings.surfaceMaterial, MoeSurfaceMaterial.frosted);
      expect(settings.glassBlurSigma, kDefaultGlassBlurSigma);
      expect(settings.glassTintFill, kDefaultGlassTintFill);
    });

    test('stored settings without material keys keep the glass fallback', () {
      final settings = mapUiModelsToAppSettings({});
      expect(settings.surfaceMaterial, MoeSurfaceMaterial.liquid);
    });

    test('mapUiModelsToAppSettings parses custom values within clamped bounds', () {
      final disabled = mapUiModelsToAppSettings({'glass_effect_enabled': false});
      expect(disabled.glassEffectEnabled, isFalse);

      final custom = mapUiModelsToAppSettings({
        'glass_effect_enabled': true,
        'glass_blur_sigma': 24.5,
      });
      expect(custom.glassEffectEnabled, isTrue);
      expect(custom.glassBlurSigma, 24.5);

      final clampedOver = mapUiModelsToAppSettings({'glass_blur_sigma': 100.0});
      expect(clampedOver.glassBlurSigma, 32.0);

      final clampedUnder = mapUiModelsToAppSettings({'glass_blur_sigma': -5.0});
      expect(clampedUnder.glassBlurSigma, 0.0);
    });

    test('copyWith updates glassEffectEnabled and glassBlurSigma', () {
      final settings = mapUiModelsToAppSettings({});
      final updated = settings.copyWith(
        glassEffectEnabled: false,
        glassBlurSigma: 8.5,
      );

      expect(updated.glassEffectEnabled, isFalse);
      expect(updated.glassBlurSigma, 8.5);
    });
  });
}

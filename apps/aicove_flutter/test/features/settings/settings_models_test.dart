import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/settings/data/support/ui_models_store_support.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

void main() {
  test('claude-fable-5 should infer as chat instead of TTS', () {
    expect(ModelType.inferFromModelId('claude-fable-5'), ModelType.chat);
  });

  test('OpenAI TTS voice ids still infer as TTS when exact', () {
    expect(ModelType.inferFromModelId('fable'), ModelType.tts);
    expect(ModelType.inferFromModelId('openai:fable'), ModelType.tts);
  });

  group('inferChatModelCapabilities', () {
    test('unrecognized model defaults to vision, tools and reasoning', () {
      expect(inferChatModelCapabilities('my-custom-model'), [
        ChatModelCapability.vision,
        ChatModelCapability.tools,
        ChatModelCapability.reasoning,
      ]);
    });

    test('recognized model keeps inferred capabilities only', () {
      expect(inferChatModelCapabilities('deepseek-flash'),
          [ChatModelCapability.tools]);
    });

    test('web capability no longer exists and stored values are dropped', () {
      expect(ChatModelCapability.fromValue('web'), isNull);
      expect(
        ChatModelCapability.normalizeValues(<String>['vision', 'web']),
        <String>['vision'],
      );
      expect(inferChatModelCapabilities('sonar-pro'), [
        ChatModelCapability.vision,
        ChatModelCapability.tools,
        ChatModelCapability.reasoning,
      ]);
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

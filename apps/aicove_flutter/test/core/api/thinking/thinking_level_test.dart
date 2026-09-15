import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/api/thinking/thinking_level.dart';
import 'package:aicove_flutter/src/core/api/thinking/thinking_level_catalog.dart';
import 'package:aicove_flutter/src/core/api/thinking/thinking_level_labels.dart';
import 'package:aicove_flutter/src/core/api/thinking/thinking_level_resolver.dart';

void main() {
  ThinkingLevelOptions opts(String provider, String model) =>
      resolveThinkingOptions(providerType: provider, modelId: model);

  group('catalog (AC4)', () {
    test('gpt-5.2 exposes native effort incl. off and xhigh', () {
      final o = opts('openai', 'gpt-5.2');
      expect(o.scheme, ThinkingScheme.openaiEffort);
      expect(o.isNative, isTrue);
      expect(o.levels, [
        ThinkingLevel.auto,
        ThinkingLevel.off,
        ThinkingLevel.low,
        ThinkingLevel.medium,
        ThinkingLevel.high,
        ThinkingLevel.xhigh,
      ]);
    });

    test('gpt-5 base uses minimal instead of off', () {
      final o = opts('openai', 'gpt-5');
      expect(o.levels, contains(ThinkingLevel.minimal));
      expect(o.levels, isNot(contains(ThinkingLevel.off)));
      expect(o.levels, isNot(contains(ThinkingLevel.xhigh)));
    });

    test('o3 supports only low/medium/high', () {
      final o = opts('openai', 'o3-mini');
      expect(o.levels, [
        ThinkingLevel.auto,
        ThinkingLevel.low,
        ThinkingLevel.medium,
        ThinkingLevel.high,
      ]);
      expect(opts('openai', 'gpt-4o').scheme, ThinkingScheme.generic);
    });

    test('unknown openai-compatible model falls back to generic 4-tier', () {
      final o = opts('openai', 'deepseek-chat');
      expect(o.scheme, ThinkingScheme.generic);
      expect(o.isNative, isFalse);
      expect(o.levels, [
        ThinkingLevel.auto,
        ThinkingLevel.off,
        ThinkingLevel.low,
        ThinkingLevel.medium,
        ThinkingLevel.high,
      ]);
    });

    test('claude-opus-5 exposes effort low..max with off', () {
      final o = opts('claude', 'claude-opus-5');
      expect(o.scheme, ThinkingScheme.claudeEffort);
      expect(o.levels, [
        ThinkingLevel.auto,
        ThinkingLevel.off,
        ThinkingLevel.low,
        ThinkingLevel.medium,
        ThinkingLevel.high,
        ThinkingLevel.xhigh,
        ThinkingLevel.max,
      ]);
    });

    test('claude-fable-5 cannot be turned off', () {
      final o = opts('claude', 'claude-fable-5');
      expect(o.levels, isNot(contains(ThinkingLevel.off)));
      expect(o.levels.first, ThinkingLevel.auto);
      expect(o.levels[1], ThinkingLevel.low);
    });

    test('claude-sonnet-4-6 has no xhigh', () {
      final o = opts('claude', 'claude-sonnet-4-6');
      expect(o.levels, isNot(contains(ThinkingLevel.xhigh)));
      expect(o.levels, contains(ThinkingLevel.max));
    });

    test('claude-sonnet-4-5 falls back to budget 4-tier', () {
      final o = opts('claude', 'claude-sonnet-4-5-20250929');
      expect(o.scheme, ThinkingScheme.claudeBudget);
      expect(o.isNative, isFalse);
    });

    test('gemini-3-flash exposes MINIMAL..HIGH', () {
      final o = opts('gemini', 'gemini-3-flash-preview');
      expect(o.scheme, ThinkingScheme.geminiLevel);
      expect(o.levels, [
        ThinkingLevel.auto,
        ThinkingLevel.minimal,
        ThinkingLevel.low,
        ThinkingLevel.medium,
        ThinkingLevel.high,
      ]);
    });

    test('gemini-3.1-pro has no MINIMAL', () {
      final o = opts('gemini', 'gemini-3.1-pro-preview');
      expect(o.levels, [
        ThinkingLevel.auto,
        ThinkingLevel.low,
        ThinkingLevel.medium,
        ThinkingLevel.high,
      ]);
    });

    test('gemini-2.5-flash falls back to budget 4-tier', () {
      final o = opts('gemini', 'gemini-2.5-flash');
      expect(o.scheme, ThinkingScheme.geminiBudget);
      expect(o.isNative, isFalse);
    });
  });

  group('coerce (AC5)', () {
    test('xhigh downgrades to high when unsupported', () {
      expect(opts('openai', 'o3').coerce(ThinkingLevel.xhigh), ThinkingLevel.high);
    });

    test('off upgrades to lowest when unsupported', () {
      expect(
        opts('claude', 'claude-fable-5').coerce(ThinkingLevel.off),
        ThinkingLevel.low,
      );
      expect(
        opts('gemini', 'gemini-3-flash').coerce(ThinkingLevel.off),
        ThinkingLevel.minimal,
      );
    });

    test('auto and supported values pass through', () {
      final o = opts('openai', 'gpt-5.2');
      expect(o.coerce(ThinkingLevel.auto), ThinkingLevel.auto);
      expect(o.coerce(ThinkingLevel.medium), ThinkingLevel.medium);
    });

    test('max on gemini-3 pro becomes high', () {
      expect(
        opts('gemini', 'gemini-3-pro').coerce(ThinkingLevel.max),
        ThinkingLevel.high,
      );
    });
  });

  group('softwareDefault (R1.5)', () {
    test('off when available', () {
      expect(opts('claude', 'claude-opus-5').softwareDefault, ThinkingLevel.off);
      expect(opts('openai', 'gpt-5.2').softwareDefault, ThinkingLevel.off);
      expect(opts('gemini', 'gemini-2.5-pro').softwareDefault, ThinkingLevel.off);
    });

    test('lowest level when off unavailable', () {
      expect(opts('claude', 'claude-fable-5').softwareDefault, ThinkingLevel.low);
      expect(opts('gemini', 'gemini-3-flash').softwareDefault, ThinkingLevel.minimal);
      expect(opts('gemini', 'gemini-3-pro').softwareDefault, ThinkingLevel.low);
      expect(opts('openai', 'o3').softwareDefault, ThinkingLevel.low);
      expect(opts('openai', 'gpt-5').softwareDefault, ThinkingLevel.minimal);
    });

    test('generic stays auto', () {
      expect(opts('openai', 'deepseek-chat').softwareDefault, ThinkingLevel.auto);
    });
  });

  group('resolver priority (AC3)', () {
    test('session beats model default beats preset beats software default', () {
      final session = resolveEffectiveThinkingLevel(
        providerType: 'openai',
        modelId: 'gpt-5.2',
        sessionLevel: ThinkingLevel.high,
        modelDefaultLevel: ThinkingLevel.medium,
        presetReasoningEffort: 'low',
      );
      expect(session.level, ThinkingLevel.high);
      expect(session.source, ThinkingLevelSource.session);

      final model = resolveEffectiveThinkingLevel(
        providerType: 'openai',
        modelId: 'gpt-5.2',
        modelDefaultLevel: ThinkingLevel.medium,
        presetReasoningEffort: 'low',
      );
      expect(model.level, ThinkingLevel.medium);
      expect(model.source, ThinkingLevelSource.model);

      final preset = resolveEffectiveThinkingLevel(
        providerType: 'openai',
        modelId: 'gpt-5.2',
        presetReasoningEffort: 'low',
      );
      expect(preset.level, ThinkingLevel.low);
      expect(preset.source, ThinkingLevelSource.preset);

      final fallback = resolveEffectiveThinkingLevel(
        providerType: 'openai',
        modelId: 'gpt-5.2',
      );
      expect(fallback.level, ThinkingLevel.off);
      expect(fallback.source, ThinkingLevelSource.softwareDefault);
    });

    test('preset auto / empty / garbage falls through to software default', () {
      for (final raw in ['auto', '', '  ', 'bogus']) {
        final r = resolveEffectiveThinkingLevel(
          providerType: 'claude',
          modelId: 'claude-fable-5',
          presetReasoningEffort: raw,
        );
        expect(r.level, ThinkingLevel.low, reason: 'raw=$raw');
        expect(r.source, ThinkingLevelSource.softwareDefault);
      }
    });

    test('session xhigh is coerced for the target model', () {
      final r = resolveEffectiveThinkingLevel(
        providerType: 'openai',
        modelId: 'o3',
        sessionLevel: ThinkingLevel.xhigh,
      );
      expect(r.level, ThinkingLevel.high);
    });
  });

  test('tryParse accepts aliases', () {
    expect(ThinkingLevel.tryParse('none'), ThinkingLevel.off);
    expect(ThinkingLevel.tryParse('XHIGH'), ThinkingLevel.xhigh);
    expect(ThinkingLevel.tryParse(null), isNull);
    expect(ThinkingLevel.tryParse('auto'), ThinkingLevel.auto);
  });
}

import 'dart:convert';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show KernelCancellation;
import 'package:aicove_flutter/src/features/background_agent/background_agent_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/context/application/runtime_context_service.dart';
import 'package:aicove_flutter/src/features/context/data/background_context_summarizer.dart';
import 'package:aicove_flutter/src/features/context/providers/context_providers.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/settings/data/support/ui_models_store_support.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_runner.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _legacyKey = 'aicove.plugins.memory.config';
const _target = 'archive:summary';
const _defaultChat = 'primary:chat';
const _other = 'primary:summary';
const _legacy = {
  'summarizeProviderId': 'archive',
  'summarizeModelName': 'summary',
  'unrelated': {'keep': true},
};

final _store = {
  'providers': [
    for (final (id, models) in [
      ('primary', ['chat', 'summary']),
      ('archive', ['summary', 'backup']),
    ])
      {
        'id': id,
        'enabled': true,
        'models': models,
        'visible_models': models,
        'capabilities': ['chat'],
      },
  ],
  'default_model': _defaultChat,
  'default_chat_models': [_defaultChat],
};

Future<ProviderContainer> _loadStoredSettings({String? legacy}) async {
  SharedPreferences.setMockInitialValues({
    kUiModelsStoreKey: jsonEncode(_store),
    if (legacy != null) _legacyKey: legacy,
  });
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await container.read(appSettingsProvider.future);
  return container;
}

Future<String> _runtimeCompactionModel(AppSettings settings) async {
  String? observed;
  final runner = TaskAgentRunner(
    loadSettings: () async => settings,
    requestConfig: ({required settings, required modelRef}) async =>
        BackgroundAgentRequestConfig(
          modelFullId: modelRef!,
          providerApiBase: 'https://example.invalid',
          providerApiKey: null,
          customConfig: const {},
          modelTemperature: null,
          modelTopP: null,
          modelContextMessageLimit: null,
        ),
    executor:
        ({
          required config,
          required tools,
          required sessionId,
          required cancellation,
        }) async {
          final runtime = config.runtimeContext as RuntimeContextService;
          final summarizer =
              await runtime.summarizerFactory() as BackgroundContextSummarizer;
          observed = summarizer.modelRef;
          return const ApiCallResult(
            replyText: 'Done',
            processedText: 'Done',
            pluginEvents: [],
            toolResults: [],
          );
        },
  );
  await runner.run(
    taskId: 'task',
    runId: 'run',
    transcript: 'Summarize task progress',
    capabilities: const TaskAgentCapabilities(),
    preset: const TaskAgentPreset(modelRef: _other),
    cancellation: KernelCancellation(),
  );
  return observed!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final deleteChannel in [false, true]) {
    final operation = deleteChannel ? 'deleteProvider' : 'deleteProviderModel';
    final survivor = deleteChannel ? _other : 'archive:backup';
    for (final (compaction, memory) in [
      (_target, _target),
      (_target, survivor),
      (survivor, _target),
    ]) {
      test(
        '$operation clears only matching refs: $compaction / $memory',
        () async {
          final container = await _loadStoredSettings();
          final notifier = container.read(appSettingsProvider.notifier);
          await notifier.setCompactionModel(compaction);
          await notifier.setMemoryModel(memory);

          if (deleteChannel) {
            await notifier.deleteProvider('archive');
          } else {
            await notifier.deleteProviderModel(
              providerId: 'archive',
              modelId: 'summary',
            );
          }

          final expectedCompaction = compaction == _target ? '' : compaction;
          final expectedMemory = memory == _target ? '' : memory;
          final prefs = await SharedPreferences.getInstance();
          final persisted =
              jsonDecode(prefs.getString(kUiModelsStoreKey)!) as Map;
          expect(persisted['compaction_model'], expectedCompaction);
          expect(persisted['memory_model'], expectedMemory);

          final state = container.read(appSettingsProvider).requireValue;
          expect(
            state.getProvider('archive')?.models ?? [],
            isNot(contains('summary')),
          );
          expect(state.compactionModel, expectedCompaction);
          expect(state.memoryModel, expectedMemory);
          final resolvedCompaction = expectedCompaction.isEmpty
              ? _defaultChat
              : expectedCompaction;
          expect(await resolveCompactionModel(state), resolvedCompaction);
          expect(
            await resolveMemoryModel(state),
            expectedMemory.isEmpty ? resolvedCompaction : expectedMemory,
          );
        },
      );
    }
  }

  final settings = mapUiModelsToAppSettings(_store);
  final primary = settings.getProvider('primary')!;
  final archive = settings.getProvider('archive')!;
  final staleSettings = {
    'deleted model': settings.copyWith(
      providers: [
        primary,
        archive.copyWith(models: ['backup'], visibleModels: ['backup']),
      ],
    ),
    'hidden model': settings.copyWith(
      providers: [
        primary,
        archive.copyWith(visibleModels: ['backup'], hiddenModels: ['summary']),
      ],
    ),
    'disabled channel': settings.copyWith(
      providers: [primary, archive.copyWith(enabled: false)],
    ),
    'deleted channel': settings.copyWith(providers: [primary]),
    'non-chat model': settings.copyWith(modelTypes: {_target: 'image'}),
  };

  for (final entry in staleSettings.entries) {
    test('${entry.key}: unavailable chat ref is rejected', () {
      expect(entry.value.resolveAvailableChatModelRef(_target), isNull);
    });

    test(
      '${entry.key}: stale explicit refs ignore a usable legacy model',
      () async {
        SharedPreferences.setMockInitialValues({
          _legacyKey: jsonEncode({
            'summarizeProviderId': 'primary',
            'summarizeModelName': 'summary',
          }),
        });
        final stale = entry.value.copyWith(
          compactionModel: _target,
          memoryModel: _target,
        );
        expect(
          [
            await resolveCompactionModel(stale),
            await resolveMemoryModel(stale),
          ],
          [_defaultChat, _defaultChat],
        );
      },
    );

    test('${entry.key}: stale legacy summary model is ignored', () async {
      SharedPreferences.setMockInitialValues({_legacyKey: jsonEncode(_legacy)});
      expect(await resolveCompactionModel(entry.value), _defaultChat);
    });

    test(
      '${entry.key}: task runtime compaction follows the task model',
      () async {
        expect(
          await _runtimeCompactionModel(
            entry.value.copyWith(compactionModel: _target),
          ),
          _other,
        );
      },
    );
  }

  test('available chat refs are normalized even if not explicitly visible', () {
    final available = settings.copyWith(
      providers: [
        primary,
        archive.copyWith(visibleModels: ['backup']),
      ],
    );
    expect(available.resolveAvailableChatModelRef('  '), isNull);
    expect(available.resolveAvailableChatModelRef('  $_target  '), _target);
    expect(
      available.resolveAvailableChatModelRef(' backup '),
      'archive:backup',
    );
  });

  test(
    'memory with a stale ref follows the available compaction model',
    () async {
      final configured = settings.copyWith(
        compactionModel: _target,
        memoryModel: 'archive:missing',
      );
      expect(await resolveMemoryModel(configured), _target);
      expect(await _runtimeCompactionModel(configured), _target);
    },
  );

  test(
    'valid legacy summary model is used before a new setting is written',
    () async {
      final container = await _loadStoredSettings(legacy: jsonEncode(_legacy));
      final state = container.read(appSettingsProvider).requireValue;
      expect(await resolveCompactionModel(state), _target);
      expect(await resolveMemoryModel(state), _target);
    },
  );

  for (final legacy in ['{', '[]']) {
    test(
      'setting the model leaves non-map legacy data alone: $legacy',
      () async {
        final container = await _loadStoredSettings(legacy: legacy);
        await container
            .read(appSettingsProvider.notifier)
            .setCompactionModel(_other);

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(_legacyKey), legacy);
        expect(
          await resolveCompactionModel(
            container.read(appSettingsProvider).requireValue,
          ),
          _other,
        );
      },
    );
  }

  for (final choice in ['', _other]) {
    test('setting "$choice" clears only legacy summary model fields', () async {
      final container = await _loadStoredSettings(legacy: jsonEncode(_legacy));
      final notifier = container.read(appSettingsProvider.notifier);
      await notifier.setCompactionModel('  $choice  ');

      final prefs = await SharedPreferences.getInstance();
      expect(jsonDecode(prefs.getString(_legacyKey)!), {
        'unrelated': {'keep': true},
      });
      final state = container.read(appSettingsProvider).requireValue;
      expect(state.compactionModel, choice);
      expect(
        await resolveCompactionModel(state),
        choice.isEmpty ? _defaultChat : choice,
      );

      await notifier.setCompactionModel('');
      expect(
        await resolveCompactionModel(
          container.read(appSettingsProvider).requireValue,
        ),
        _defaultChat,
      );
    });
  }
}

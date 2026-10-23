// Headless real-data acceptance for the agent kernel (ADR0064 batch 1c).
//
// Boots the real app (same providers, storage and plugins as lib/main.dart),
// then sends scripted messages through ChatActions.send — the entry the
// composer uses — and writes a JSON report next to the database.
//
// Build only against an isolated data copy (separate bundle id); see
// tool/DIAGNOSTICS.md「Agent 内核真实数据验收」. Never run against real data.
// _checkIsolation refuses to start unless the running bundle and its
// container are the prepared copy, and cloud/LAN sync are overridden off.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:aicove_flutter/src/app.dart';
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/features/chat/chat_actions.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/services/api_runner.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/sync/domain/lan_sync_port.dart';
import 'package:aicove_flutter/src/features/sync/providers/cloud_sync_provider.dart';
import 'package:aicove_flutter/src/features/sync/providers/lan_sync_provider.dart';

const _tag = 'KernelAcceptance';

/// Scenarios as `id|conversationId|callFlowMode|expectedImageRoute|text`,
/// separated by `;;`. Empty mode/route fields mean "leave as is"/"any".
const _scenarioSpec = String.fromEnvironment('AICOVE_ACCEPTANCE_SCENARIOS');
const _turnTimeout = Duration(minutes: 4);

/// Bundle id of the prepared data copy; must match the running app.
const _isolatedBundleId = String.fromEnvironment('AICOVE_ACCEPTANCE_BUNDLE_ID');

/// Bundle ids that hold real user data.
const _realBundleIds = {'com.example.aicoveFlutter'};

/// Created in the copy's Documents directory once the copy is prepared
/// (database copied, local_credentials removed).
const _isolationMarker = 'kernel_acceptance_isolated';

/// Credentials the app generates locally on every launch.
const _allowedCredentialFiles = {'diagnostic_access_token_v1.json'};

/// Returns why this process must not run, or null when it is the prepared
/// isolated copy. Touches no app storage.
Future<String?> _checkIsolation() async {
  if (_isolatedBundleId.isEmpty) {
    return 'AICOVE_ACCEPTANCE_BUNDLE_ID is not set';
  }
  if (_realBundleIds.contains(_isolatedBundleId)) {
    return '$_isolatedBundleId is the real app bundle';
  }
  final bundleId = (await PackageInfo.fromPlatform()).packageName;
  if (bundleId != _isolatedBundleId) {
    return 'running bundle $bundleId != $_isolatedBundleId';
  }
  final docs = await getApplicationDocumentsDirectory();
  final support = await getApplicationSupportDirectory();
  const container = '/Library/Containers/$_isolatedBundleId/';
  for (final dir in [docs, support]) {
    if (!dir.path.contains(container)) {
      return '${dir.path} is outside the $_isolatedBundleId container';
    }
  }
  if (!File(p.join(docs.path, _isolationMarker)).existsSync()) {
    return 'isolation marker ${p.join(docs.path, _isolationMarker)} missing';
  }
  // Account, LAN pairing and access tokens must be gone; the app recreates
  // only its local diagnostic token on launch.
  final credentials = Directory(p.join(support.path, 'local_credentials'));
  if (credentials.existsSync()) {
    for (final entry in credentials.listSync()) {
      final name = p.basename(entry.path);
      if (!_allowedCredentialFiles.contains(name)) {
        return 'credential $name present; remove local_credentials first';
      }
    }
  }
  return null;
}

class _Scenario {
  _Scenario(this.id, this.conversationId, this.mode, this.route, this.text);
  final String id;
  final String conversationId;
  final CallFlowMode? mode;
  final String route;
  final String text;
}

List<_Scenario> _parseScenarios() => [
  for (final raw in _scenarioSpec.split(';;'))
    if (raw.trim().isNotEmpty)
      () {
        final parts = raw.split('|');
        if (parts.length != 5) throw FormatException('bad scenario: $raw');
        final mode = parts[2].trim();
        return _Scenario(
          parts[0].trim(),
          parts[1].trim(),
          mode.isEmpty ? null : CallFlowMode.values.byName(mode),
          parts[3].trim(),
          parts[4],
        );
      }(),
];

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final refusal = await _checkIsolation();
  if (refusal != null) {
    stderr.writeln('[$_tag] refused: $refusal');
    exit(2);
  }
  final container = ProviderContainer(
    overrides: [
      // Never connect: the copy must not sync with the account or LAN peers.
      cloudSyncProvider.overrideWith(CloudSyncController.new),
      lanSyncPortProvider.overrideWith(
        (ref) => Completer<LanSyncPort>().future,
      ),
    ],
  );
  runApp(UncontrolledProviderScope(container: container, child: const MyApp()));
  final report = <String, Object?>{
    'startedAt': DateTime.now().toIso8601String(),
    'kernelChat': true,
    'scenarios': <Object?>[],
  };
  try {
    await _run(container, report);
  } catch (error, stack) {
    report['fatal'] = '$error\n$stack';
  }
  report['finishedAt'] = DateTime.now().toIso8601String();
  final dir = await getApplicationDocumentsDirectory();
  final out = File(p.join(dir.path, 'kernel_acceptance_report.json'));
  await out.writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  AppLogger.info(_tag, 'report written', metadata: {'path': out.path});
  await Future<void>.delayed(const Duration(seconds: 2));
  exit(0);
}

Future<void> _run(ProviderContainer c, Map<String, Object?> report) async {
  final scenarios = _parseScenarios();
  if (scenarios.isEmpty) throw StateError('no scenarios');
  final settingsNotifier = c.read(appSettingsProvider.notifier);
  var settings = await c.read(appSettingsProvider.future);
  final originalFlow = settings.callFlowSettings;
  report['defaultModel'] = settings.defaultModelName;
  report['originalCallFlowMode'] = originalFlow.mode.name;
  // Let startup work (conversation warmup, plugin init) settle first.
  await Future<void>.delayed(const Duration(seconds: 8));

  final results = report['scenarios'] as List<Object?>;
  try {
    for (final s in scenarios) {
      final entry = <String, Object?>{
        'id': s.id,
        'conversationId': s.conversationId,
      };
      results.add(entry);
      if (s.mode != null) {
        await settingsNotifier.updateCallFlowSettings(
          settings.callFlowSettings.copyWith(mode: s.mode),
        );
      }
      settings = await c.read(appSettingsProvider.future);
      entry['callFlowMode'] = settings.callFlowSettings.mode.name;
      final model = settings.defaultModelName;
      final route = settings.resolveEffectiveImageGenerationRoute(model).name;
      entry['imageRoute'] = route;
      if (s.route.isNotEmpty && s.route != route) {
        entry['skipped'] = 'default model $model resolves to $route route';
        continue;
      }

      c.read(activeConversationIdProvider.notifier).state = s.conversationId;
      await Future<void>.delayed(const Duration(seconds: 1));
      final conv = c.read(activeConversationProvider);
      if (conv == null) {
        entry['error'] = 'conversation not found';
        continue;
      }
      entry['conversationModel'] = conv.sessionProvider ?? conv.defaultProvider;
      entry['sentAt'] = DateTime.now().toIso8601String();
      final watch = Stopwatch()..start();
      try {
        await c.read(chatActionsProvider).send(s.text).timeout(_turnTimeout);
        await _waitIdle(c, s.conversationId);
      } catch (error) {
        entry['error'] = '$error';
      }
      entry['elapsedMs'] = watch.elapsedMilliseconds;
      entry['uiError'] = c.read(errorProvider);
      entry['doneAt'] = DateTime.now().toIso8601String();
      AppLogger.info(_tag, 'scenario done', metadata: entry);
      // Media follow-ups (image placement, TTS) finish after the turn.
      await Future<void>.delayed(const Duration(seconds: 20));
    }
  } finally {
    await settingsNotifier.updateCallFlowSettings(originalFlow);
  }
}

Future<void> _waitIdle(ProviderContainer c, String convId) async {
  final deadline = DateTime.now().add(_turnTimeout);
  while (c.read(conversationSendingProvider(convId))) {
    if (DateTime.now().isAfter(deadline))
      throw TimeoutException('still sending');
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

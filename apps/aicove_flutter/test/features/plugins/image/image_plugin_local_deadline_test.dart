import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart';
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_plugin.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../task_agent/agent_execution_reliability_test.dart' as app;

enum _Phase { settings, path, directoryExists, directoryCreate, file }

class _Settings extends AppSettingsNotifier {
  _Settings(this.load);
  final Future<AppSettings> Function() load;
  @override
  Future<AppSettings> build() => load();
}

/// Fire only the local 30-second deadline, without waiting in real time or
/// changing the production constant. Network and runner timers stay real.
class _LocalTimers {
  final entries = <({Timer timer, void Function() expire})>[];

  ZoneSpecification get specification => ZoneSpecification(
    createTimer: (self, parent, zone, duration, callback) {
      final timer = parent.createTimer(zone, duration, callback);
      if (duration == const Duration(seconds: 30)) {
        entries.add((timer: timer, expire: () => zone.runGuarded(callback)));
      }
      return timer;
    },
  );

  void expire() {
    final active = entries.where((entry) => entry.timer.isActive).toList();
    expect(active, hasLength(1));
    active.single.timer.cancel();
    active.single.expire();
  }
}

class _RealHttp extends HttpOverrides {}

final class _Storage extends IOOverrides {
  _Storage(this.phase);
  final _Phase phase;
  final entered = Completer<void>();
  final release = Completer<void>();
  final operations = <String>[];

  Future<void> hold(_Phase at) async {
    operations.add(at.name);
    if (phase != at) return;
    if (!entered.isCompleted) entered.complete();
    await release.future;
  }

  @override
  Directory createDirectory(String path) => path.contains('generated_images')
      ? _OutputDirectory(this, path)
      : super.createDirectory(path);

  @override
  File createFile(String path) => path.contains('generated_images')
      ? _OutputFile(this, path)
      : super.createFile(path);
}

class _OutputDirectory implements Directory {
  _OutputDirectory(this.storage, this.path);
  final _Storage storage;
  @override
  final String path;

  @override
  Future<bool> exists() async {
    await storage.hold(_Phase.directoryExists);
    return false;
  }

  @override
  Future<Directory> create({bool recursive = false}) async {
    await storage.hold(_Phase.directoryCreate);
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _OutputFile implements File {
  _OutputFile(this.storage, this.path);
  final _Storage storage;
  @override
  final String path;

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    await storage.hold(_Phase.file);
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(AppLogger.clear);

  for (final phase in _Phase.values) {
    for (final cancel in [false, true]) {
      test(
        'draw_image ${phase.name} never completes: ${cancel ? 'conversation stop exits' : '30s deadline bounds tool'}',
        () async {
          final storage = _Storage(phase);
          final timers = _LocalTimers();
          final cancellation = KernelCancellation();
          final settingsEntered = Completer<void>();
          final settingsRelease = Completer<AppSettings>();
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          var submissions = 0;
          server.listen((request) async {
            await request.drain<void>();
            submissions++;
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              '{"data":[{"b64_json":"AQ=="},{"b64_json":"Ag=="}]}',
            );
            await request.response.close();
          });
          addTearDown(() => server.close(force: true));
          const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          messenger.setMockMethodCallHandler(pathChannel, (_) async {
            await storage.hold(_Phase.path);
            return '/unused-image-deadline-test';
          });
          addTearDown(
            () => messenger.setMockMethodCallHandler(pathChannel, null),
          );
          const chatModel = 'openai:gpt-4o-mini';
          final settings = mapUiModelsToAppSettings({}).copyWith(
            imageGenerationEnabled: true,
            callFlowSettings: const CallFlowSettings(
              mode: CallFlowMode.call,
              toolTimeoutSeconds: 1,
            ),
            modelConfigs: const {
              chatModel: ModelConfig(chatCapabilities: ['tools', 'vision']),
            },
            modelTypes: const {'local:image': 'image'},
            modelProviderMap: const {'local:image': 'local'},
            providers: [
              ProviderAuth(
                id: 'local',
                apiKeys: const ['local-stage-key'],
                apiBaseUrl: 'http://127.0.0.1:${server.port}',
                models: const ['image'],
                visibleModels: const ['image'],
                capabilities: const ['image'],
              ),
            ],
          );
          var settingsStalled = false;
          final container = ProviderContainer(
            overrides: [
              appSettingsProvider.overrideWith(
                () => _Settings(() {
                  if (!settingsStalled) return Future.value(settings);
                  if (!settingsEntered.isCompleted) settingsEntered.complete();
                  return settingsRelease.future;
                }),
              ),
            ],
          );
          addTearDown(container.dispose);
          await container.read(appSettingsProvider.future);
          final plugin = container.read(
            Provider(
              (ref) => ImagePlugin(
                const ImageConfig(
                  selectedProviderId: 'local',
                  selectedModelId: 'local:image',
                  timeoutSeconds: 10,
                ),
                ref,
                requestSettings: phase == _Phase.settings ? null : settings,
                isRequestSnapshot: phase != _Phase.settings,
              ),
            ),
          );
          final tool = plugin.getTools().single;
          expect(tool.managesDeadline, true);
          if (phase == _Phase.settings) {
            settingsStalled = true;
            container.invalidate(appSettingsProvider);
          }
          final model = app.ScriptClient(
            (round, _) async => round == 1
                ? const SendMessageRichResult(
                    text: '',
                    toolResults: [],
                    toolCalls: [
                      ToolCall(
                        id: 'draw',
                        name: 'draw_image',
                        arguments: {'prompt': 'cat'},
                      ),
                    ],
                  )
                : app.done,
          );
          await IOOverrides.runWithIOOverrides(
            () => HttpOverrides.runWithHttpOverrides(() async {
              // Observe the runner's actual invocation: managesDeadline makes it
              // await the real tool, not just RequestControl's cancelled wrapper.
              final pending = runZoned(
                () =>
                    ChatSendApiRunner.withAgentClientFactory(
                      agentClientFactory: (_) => model,
                    ).executeApiCall(
                      config: ApiConfig(
                        settings: settings,
                        modelFullId: chatModel,
                        providerApiBase: 'https://unused.test',
                        customConfig: const {},
                        messages: const [
                          {'role': 'user', 'content': 'draw a cat'},
                        ],
                      ),
                      sessionId: 'local-stage-${server.port}',
                      userText: null,
                      responseProcessors: const [],
                      availableTools: [tool],
                      cancellation: cancellation,
                    ),
                zoneSpecification: timers.specification,
              );
              var settled = false;
              pending.then<void>(
                (_) => settled = true,
                onError: (Object _, StackTrace __) => settled = true,
              );
              final finished = cancel
                  ? expectLater(
                      pending.timeout(const Duration(seconds: 5)),
                      throwsA(isA<KernelCancelledException>()),
                    )
                  : null;
              await (phase == _Phase.settings
                      ? settingsEntered.future
                      : storage.entered.future)
                  .timeout(const Duration(seconds: 5));
              expect(settled, false);
              if (cancel) {
                cancellation.cancel();
                await finished;
              } else {
                timers.expire();
                final result = await pending.timeout(
                  const Duration(seconds: 2),
                );
                expect(result.status, ApiRunStatus.completed);
                final payload =
                    jsonDecode(
                          result.rawToolResults
                              .singleWhere(
                                (result) => result.name == 'draw_image',
                              )
                              .result,
                        )
                        as Map;
                expect(payload['success'], false);
                expect(payload['error'], contains('TimeoutException'));
              }
              expect(
                timers.entries.where((entry) => entry.timer.isActive),
                isEmpty,
              );
              expect(submissions, phase == _Phase.settings ? 0 : 1);
              final operationsAtExit = List<String>.of(storage.operations);
              // Native Futures cannot be forcibly stopped. A late completion
              // must not start another directory operation, write or submission.
              settingsRelease.complete(settings);
              storage.release.complete();
              await Future<void>.delayed(Duration.zero);
              await Future<void>.delayed(Duration.zero);
              expect(storage.operations, operationsAtExit);
              expect(submissions, phase == _Phase.settings ? 0 : 1);
              expect(
                AppLogger.entries.value.any(
                  (entry) =>
                      entry.message == 'Image generated by tool' &&
                      entry.metadata?['model'] == 'image',
                ),
                false,
              );
            }, _RealHttp()),
            storage,
          );
        },
      );
    }
  }
}

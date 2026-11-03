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
import 'package:shared_preferences/shared_preferences.dart';

import '../../task_agent/agent_execution_reliability_test.dart' as app;

class _RealHttpOverrides extends HttpOverrides {}

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jJ1kAAAAASUVORK5CYII=';

/// Only the two occupying requests are held; draw_image may complete as soon
/// as a slot is available. Every image call uses the real HTTP adapter.
class _ImageServer {
  _ImageServer(this.server) {
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      prompts.add(body['prompt'] as String);
      if (prompts.length == 2) occupied.complete();
      if ((body['prompt'] as String).startsWith('occupant-')) {
        await release.future;
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'data': [
            {'b64_json': _png},
          ],
        }),
      );
      await request.response.close();
    });
  }

  final HttpServer server;
  final prompts = <String>[];
  final occupied = Completer<void>();
  final release = Completer<void>();
  String get baseUrl => 'http://127.0.0.1:${server.port}';
  void unblock() {
    if (!release.isCompleted) release.complete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final stopConversation in [false, true]) {
    test(
      stopConversation
          ? 'stopping a conversation cancels queued real draw_image without HTTP submission'
          : 'queued real draw_image survives the generic tool deadline across clients',
      () async {
        SharedPreferences.setMockInitialValues({});
        final output = Directory('build/draw_image_queue_deadline_test');
        await output.create(recursive: true);
        final temp = await output.createTemp('images-');
        addTearDown(() => temp.delete(recursive: true));
        const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          pathChannel,
          (_) async => temp.absolute.path,
        );
        addTearDown(
          () => messenger.setMockMethodCallHandler(pathChannel, null),
        );

        final imageServer = _ImageServer(
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        );
        addTearDown(() => imageServer.server.close(force: true));
        final container = ProviderContainer();
        addTearDown(container.dispose);

        await HttpOverrides.runWithHttpOverrides(() async {
          // Independent clients fill the same channel used by ImagePlugin's
          // internally constructed AgentApiClient.
          final clients = [AgentApiClient(), AgentApiClient()];
          final occupants = [
            for (var i = 0; i < clients.length; i++)
              clients[i].generateImage(
                provider: 'openai',
                model: 'image',
                prompt: 'occupant-$i',
                providerApiBase: imageServer.baseUrl,
                providerApiKey: 'queue-test-key',
              ),
          ];
          final allOccupants = Future.wait(occupants);
          addTearDown(() async {
            imageServer.unblock();
            await allOccupants;
          });
          await imageServer.occupied.future.timeout(const Duration(seconds: 5));

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
                apiKeys: const ['queue-test-key'],
                apiBaseUrl: imageServer.baseUrl,
                models: const ['image'],
                visibleModels: const ['image'],
                capabilities: const ['image'],
              ),
            ],
          );
          final plugin = container.read(
            Provider(
              (ref) => ImagePlugin(
                const ImageConfig(
                  selectedProviderId: 'local',
                  selectedModelId: 'local:image',
                  timeoutSeconds: 10,
                ),
                ref,
                requestSettings: settings,
                isRequestSnapshot: true,
              ),
            ),
          );
          final tool = plugin.getTools().single;
          final started = Completer<void>();
          void onLog() {
            if (!started.isCompleted &&
                AppLogger.entries.value.last.message == '图片生成请求开始') {
              started.complete();
            }
          }

          // Attach after the occupants, whose API logs use a different message.
          AppLogger.entries.addListener(onLog);
          addTearDown(() => AppLogger.entries.removeListener(onLog));
          final cancellation = KernelCancellation();
          final model = app.ScriptClient(
            (round, _) async => round == 1
                ? const SendMessageRichResult(
                    text: '',
                    toolResults: [],
                    toolCalls: [
                      ToolCall(
                        id: 'draw',
                        name: 'draw_image',
                        arguments: {'prompt': 'queued-cat'},
                      ),
                    ],
                  )
                : app.done,
          );
          var settled = false;
          final pending =
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
                sessionId: 'queue-${imageServer.server.port}',
                userText: null,
                responseProcessors: const [],
                availableTools: [tool],
                cancellation: cancellation,
              );
          pending.then<void>(
            (_) => settled = true,
            onError: (Object _, StackTrace __) => settled = true,
          );
          addTearDown(() async {
            cancellation.cancel();
            imageServer.unblock();
            try {
              await pending;
            } on KernelCancelledException {
              // The compatibility runner reports cancellation by throwing.
            }
          });
          await started.future.timeout(const Duration(seconds: 5));

          // The only elapsed-time wait tests the one-second generic deadline;
          // network occupancy and release remain controlled by completers.
          await Future<void>.delayed(const Duration(milliseconds: 1250));
          final submissionsWhileOccupied = List<String>.of(imageServer.prompts);
          final settledWhileOccupied = settled;
          if (stopConversation) {
            cancellation.cancel();
            await expectLater(
              pending.timeout(const Duration(seconds: 2)),
              throwsA(isA<KernelCancelledException>()),
            );
            expect(
              imageServer.release.isCompleted,
              false,
              reason:
                  'Cancellation must settle without releasing the occupied slots.',
            );
            imageServer.unblock();
            await allOccupants;
            expect(imageServer.prompts, isNot(contains('queued-cat')));
          } else {
            imageServer.unblock();
            await allOccupants;
            final result = await pending.timeout(const Duration(seconds: 5));
            expect(
              settledWhileOccupied,
              false,
              reason:
                  'Queue waiting must not consume the generic tool deadline.',
            );
            expect(result.status, ApiRunStatus.completed);
            final drawResult = result.rawToolResults.singleWhere(
              (r) => r.name == 'draw_image',
            );
            expect(jsonDecode(drawResult.result)['success'], true);
            expect(
              imageServer.prompts.where((p) => p == 'queued-cat'),
              hasLength(1),
            );
          }
          expect(
            submissionsWhileOccupied,
            hasLength(2),
            reason:
                'The plugin must share the two OpenAI slots across client instances.',
          );
        }, _RealHttpOverrides());
      },
    );
  }
}

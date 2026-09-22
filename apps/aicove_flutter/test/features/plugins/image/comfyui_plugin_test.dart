import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/core/api/image_providers/comfyui_workflow.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';

class _Settings extends AppSettingsNotifier {
  _Settings(this.settings);
  final AppSettings settings;
  @override
  Future<AppSettings> build() async => settings;
}

class _LocalHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'keyless tool, inline save and regenerate reuse the original workflow',
    () async {
      SharedPreferences.setMockInitialValues({});
      final temp = await Directory.systemTemp.createTemp('comfy-plugin-test');
      addTearDown(() => temp.delete(recursive: true));
      const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(pathChannel, (_) async => temp.path);
      addTearDown(() => messenger.setMockMethodCallHandler(pathChannel, null));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final submissions = <Map<String, dynamic>>[];
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jJ1kAAAAASUVORK5CYII=',
      );
      server.listen((request) async {
        if (request.method == 'POST') {
          submissions.add(
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>,
          );
          request.response.write(jsonEncode({'prompt_id': 'job'}));
        } else if (request.uri.path.startsWith('/history/')) {
          request.response.write(
            jsonEncode({
              'job': {
                'status': {'status_str': 'success'},
                'outputs': {
                  '9': {
                    'images': [
                      {
                        'filename': 'image.png',
                        'type': 'output',
                        'subfolder': '',
                      },
                    ],
                  },
                },
              },
            }),
          );
        } else {
          request.response.add(png);
        }
        await request.response.close();
      });
      const workflow = {
        '6': {
          'class_type': 'CLIPTextEncode',
          'inputs': {'text': '%prompt%'},
        },
        '3': {
          'class_type': 'KSampler',
          'inputs': {'steps': '%steps%', 'cfg': '%cfg_scale%'},
        },
        '9': {
          'class_type': 'SaveImage',
          'inputs': {
            'images': ['8', 0],
          },
        },
      };
      final settings = mapUiModelsToAppSettings({}).copyWith(
        imageGenerationEnabled: true,
        modelTypes: {'local:${ComfyUIWorkflow.modelId}': 'image'},
        providers: [
          ProviderAuth(
            id: 'local',
            apiBaseUrl: 'http://127.0.0.1:${server.port}',
            apiKeys: [],
            models: [ComfyUIWorkflow.modelId],
            visibleModels: [ComfyUIWorkflow.modelId],
            capabilities: ['image'],
            customConfig: {
              'requestFormat': 'comfyui',
              'comfyWorkflow': workflow,
            },
          ),
        ],
      );
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith(() => _Settings(settings)),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      const imageConfig = ImageConfig(
        selectedProviderId: 'local',
        selectedModelId: 'local:${ComfyUIWorkflow.modelId}',
      );
      final plugin = container.read(
        Provider((ref) => ImagePlugin(imageConfig, ref)),
      );
      expect(plugin.getTools().single.name, 'draw_image');
      expect(plugin.getTools().single.parameters.containsKey('steps'), true);
      await HttpOverrides.runWithHttpOverrides(() async {
        final result = await plugin.generateInlineImage(
          prompt: '{"prompt":"cat", "steps":12,"guidance_scale":3.5}',
        );
        expect(result.error, isNull);
        expect(
          result.generationSnapshot?.customParameters['comfyWorkflow'],
          workflow,
        );
        final snapshot = result.generationSnapshot!;
        expect(submissions.single['prompt']['3']['inputs']['steps'], 12);
        final changed = settings.copyWith(
          providers: [
            settings.providers.single.copyWith(
              customConfig: {
                'requestFormat': 'comfyui',
                'comfyBindings': {'prompt': 'changed.text'},
                'comfyOutputNode': 'changed',
                'comfyWorkflow': {
                  'changed': {
                    'class_type': 'CLIPTextEncode',
                    'inputs': {'text': '%prompt%'},
                  },
                },
              },
            ),
          ],
        );
        final replay = container.read(
          Provider(
            (ref) => ImagePlugin(
              imageConfig,
              ref,
              requestSettings: changed,
              isRequestSnapshot: true,
            ),
          ),
        );
        final regenerated = await replay.regenerateImage(snapshot);
        expect(regenerated.error, isNull);
        expect(submissions.last['prompt'].containsKey('6'), true);
        expect(submissions.last['prompt'].containsKey('changed'), false);
        expect(submissions.last['prompt']['3']['inputs']['steps'], 12);
      }, _LocalHttp());
    },
  );
}

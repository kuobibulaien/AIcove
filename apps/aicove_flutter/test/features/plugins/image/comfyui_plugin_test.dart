import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/core/models/image_generation_snapshot.dart';
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
    'explicit modes roundtrip and share validation with effective requests',
    () {
      final channel = {
        'comfyWorkflow': {
          '6': {
            'class_type': 'CLIPTextEncode',
            'inputs': {'text': '%prompt%'},
          },
        },
        'comfyBindings': {'prompt': '6.text'},
        'comfyOutputNode': '6',
        'requestFormat': 'comfyui',
      };
      final legacy = ImageConfig.fromJson({});
      expect(legacy.comfyWorkflowMode, 'inherit');
      expect(
        legacy.effectiveComfyWorkflowMode(
          modelId: ComfyUIWorkflow.modelId,
          providerCustomConfig: channel,
        ),
        'custom',
      );
      expect(
        legacy.effectiveComfyWorkflowMode(
          modelId: 'model.safetensors',
          providerCustomConfig: channel,
        ),
        'standard',
      );
      final standard = legacy.copyWith(
        comfyWorkflowMode: 'standard',
        comfyWorkflowConfig: channel,
      );
      expect(
        ImageConfig.fromJson(standard.toJson()).comfyWorkflowMode,
        'standard',
      );
      final effective = standard.buildComfyCustomConfig(
        modelId: 'model.safetensors',
        providerCustomConfig: channel,
      );
      for (final key in ['comfyWorkflow', 'comfyBindings', 'comfyOutputNode']) {
        expect(effective.containsKey(key), false);
        expect(channel.containsKey(key), true);
      }
      expect(
        () => standard.validateComfyConfiguration(
          modelId: ComfyUIWorkflow.modelId,
          providerCustomConfig: channel,
        ),
        throwsFormatException,
      );
      final custom = legacy.copyWith(
        comfyWorkflowMode: 'custom',
        comfyWorkflowConfig: channel,
        comfyLoraName: 'inactive.safetensors',
        comfyLoraStrength: 3,
      );
      expect(
        () => custom.validateComfyConfiguration(
          modelId: ComfyUIWorkflow.modelId,
          providerCustomConfig: channel,
        ),
        returnsNormally,
      );
      expect(
        custom
            .buildComfyCustomConfig(
              modelId: ComfyUIWorkflow.modelId,
              providerCustomConfig: channel,
            )
            .containsKey('comfyLoraName'),
        false,
      );
      expect(
        () => legacy
            .copyWith(comfyWorkflowMode: 'custom')
            .validateComfyConfiguration(
              modelId: 'model.safetensors',
              providerCustomConfig: channel,
            ),
        throwsFormatException,
      );
      expect(
        () => legacy
            .copyWith(
              comfyWorkflowMode: 'standard',
              comfyLoraName: 'active',
              comfyLoraStrength: 3,
            )
            .validateComfyConfiguration(modelId: 'model.safetensors'),
        throwsFormatException,
      );
    },
  );

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
        callFlowSettings: const CallFlowSettings(mode: CallFlowMode.call),
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

        // Preset-level standard Checkpoint + LoRA mode (no custom workflow JSON).
        submissions.clear();
        final ckptSettings = settings.copyWith(
          modelTypes: {'local:illustrious.safetensors': 'image'},
          providers: [
            ProviderAuth(
              id: 'local',
              apiBaseUrl: 'http://127.0.0.1:${server.port}',
              apiKeys: const [],
              models: const ['illustrious.safetensors'],
              visibleModels: const ['illustrious.safetensors'],
              capabilities: const ['image'],
              customConfig: const {
                'requestFormat': 'comfyui',
                'comfyWorkflow': workflow,
                'comfyBindings': {'prompt': '6.text'},
                'comfyOutputNode': '9',
              },
            ),
          ],
        );
        const loraConfig = ImageConfig(
          selectedProviderId: 'local',
          selectedModelId: 'local:illustrious.safetensors',
          comfyLoraName: 'kokomi_v1.safetensors',
          comfyLoraStrength: 0.75,
          comfySampler: 'dpmpp_2m',
          comfyScheduler: 'karras',
        );
        final loraPlugin = container.read(
          Provider(
            (ref) => ImagePlugin(
              loraConfig,
              ref,
              requestSettings: ckptSettings,
              isRequestSnapshot: true,
            ),
          ),
        );
        final loraResult = await loraPlugin.generateInlineImage(
          prompt: '{"prompt":"1girl, smile","steps":20,"guidance_scale":5.0}',
        );
        expect(loraResult.error, isNull);
        expect(
          submissions.single['prompt']['4']['inputs']['ckpt_name'],
          'illustrious.safetensors',
        );
        expect(
          submissions.single['prompt']['10']['inputs']['lora_name'],
          'kokomi_v1.safetensors',
        );
        expect(
          submissions.single['prompt']['10']['inputs']['strength_model'],
          0.75,
        );
        expect(
          submissions.single['prompt']['3']['inputs']['sampler_name'],
          'dpmpp_2m',
        );
        expect(submissions.single['prompt']['3']['inputs']['scheduler'], 'karras');
        // Replay keeps the original sampler even after the preset changes.
        final changedSamplerPlugin = container.read(
          Provider(
            (ref) => ImagePlugin(
              loraConfig.copyWith(
                comfySampler: 'euler_ancestral',
                clearComfyScheduler: true,
              ),
              ref,
              requestSettings: ckptSettings,
              isRequestSnapshot: true,
            ),
          ),
        );
        final loraReplay = await changedSamplerPlugin.regenerateImage(
          loraResult.generationSnapshot!,
        );
        expect(loraReplay.error, isNull);
        expect(
          submissions.last['prompt']['3']['inputs']['sampler_name'],
          'dpmpp_2m',
        );
        expect(submissions.last['prompt']['3']['inputs']['scheduler'], 'karras');
        expect(
          submissions.last['prompt']['10']['inputs']['lora_name'],
          'kokomi_v1.safetensors',
        );

        final noLoraPlugin = container.read(
          Provider(
            (ref) => ImagePlugin(
              loraConfig.copyWith(clearComfyLoraName: true),
              ref,
              requestSettings: ckptSettings,
              isRequestSnapshot: true,
            ),
          ),
        );
        final noLora = await noLoraPlugin.generateInlineImage(prompt: 'cat');
        expect(noLora.error, isNull);
        expect(
          noLora.generationSnapshot!.customParameters.containsKey(
            'comfyLoraName',
          ),
          true,
        );
        expect(
          noLora.generationSnapshot!.customParameters['comfyLoraName'],
          isNull,
        );
        expect(
          noLora.generationSnapshot!.customParameters['comfyLoraStrength'],
          1.0,
        );
        final changedLora = ckptSettings.copyWith(
          providers: [
            ckptSettings.providers.single.copyWith(
              customConfig: {
                ...ckptSettings.providers.single.customConfig,
                'comfyLoraName': 'later.safetensors',
                'comfyLoraStrength': 0.2,
              },
            ),
          ],
        );
        final noLoraReplay = container.read(
          Provider(
            (ref) => ImagePlugin(
              loraConfig,
              ref,
              requestSettings: changedLora,
              isRequestSnapshot: true,
            ),
          ),
        );
        await noLoraReplay.regenerateImage(noLora.generationSnapshot!);
        expect(submissions.last['prompt'].containsKey('10'), false);
        // Legacy snapshots may omit both no-LoRA state and default strength.
        final oldNoLora = noLora.generationSnapshot!.toJson();
        oldNoLora['customParameters'] = <String, dynamic>{};
        await noLoraReplay.regenerateImage(
          ImageGenerationSnapshot.tryRead(oldNoLora)!,
        );
        expect(submissions.last['prompt'].containsKey('10'), false);
        final oldLora = loraResult.generationSnapshot!.toJson();
        (oldLora['customParameters'] as Map).remove('comfyLoraStrength');
        await noLoraReplay.regenerateImage(
          ImageGenerationSnapshot.tryRead(oldLora)!,
        );
        expect(
          submissions.last['prompt']['10']['inputs']['strength_model'],
          1.0,
        );
      }, _LocalHttp());
    },
  );
}

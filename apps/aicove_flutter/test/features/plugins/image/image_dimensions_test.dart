import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_plugin.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'inline and tool results carry per-image dimensions and unique paths',
    () async {
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp(
        'image-dimensions',
      );
      addTearDown(() => directory.delete(recursive: true));
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final settings = mapUiModelsToAppSettings({}).copyWith(
        imageGenerationEnabled: true,
        modelTypes: {'local:image': 'image'},
        modelProviderMap: {'local:image': 'local'},
        providers: [
          const ProviderAuth(
            id: 'local',
            apiKeys: ['test'],
            apiBaseUrl: 'https://local.test/v1',
            models: ['image'],
            visibleModels: ['image'],
            capabilities: ['image'],
          ),
        ],
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final plugin = container.read(
        Provider(
          (ref) => ImagePlugin(
            const ImageConfig(
              selectedProviderId: 'local',
              selectedModelId: 'local:image',
            ),
            ref,
            requestSettings: settings,
            isRequestSnapshot: true,
          ),
        ),
      );
      final images = [
        img.encodePng(img.Image(width: 23, height: 41)),
        img.encodeJpg(img.Image(width: 51, height: 17)),
        <int>[1, 2, 3, 4],
      ];
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'data': [
              for (final bytes in images) {'b64_json': base64Encode(bytes)},
            ],
          }),
          200,
        ),
      );
      addTearDown(client.close);
      await http.runWithClient(() async {
        final results = await Future.wait([
          plugin.generateInlineImage(prompt: 'cat'),
          plugin.generateInlineImage(prompt: 'dog'),
        ]);
        for (final result in results) {
          expect(result.error, isNull);
          expect(result.images.map((image) => (image.width, image.height)), [
            (23, 41),
            (51, 17),
            (null, null),
          ]);
          expect((result.width, result.height), (23, 41));
        }
        expect(
          results.expand((result) => result.localPaths).toSet(),
          hasLength(6),
        );
        final json =
            jsonDecode((await plugin.runDrawImageToolForDebug(prompt: 'cat'))!)
                as Map;
        expect(
          (json['images'] as List).map(
            (image) => (image['width'], image['height']),
          ),
          [(23, 41), (51, 17), (null, null)],
        );
        expect(
          plugin.resolveInlineImageTargetDimensions(
            prompt: '{"prompt":"cat","width":512,"height":768}',
          ),
          (width: 512, height: 768),
        );
      }, () => client);
    },
  );
}

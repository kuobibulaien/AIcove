import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_manager.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/image_generation_test_page.dart';

class DeferredImagePlugin extends ImagePlugin {
  DeferredImagePlugin(Ref ref, this.result) : super(const ImageConfig(), ref);
  final Completer<String?> result;
  int calls = 0;
  @override
  Future<String?> runDrawImageToolForDebug({
    required String prompt,
    String? negativePrompt,
    int? width,
    int? height,
  }) {
    calls++;
    return result.future;
  }
}

void main() {
  for (final throws in [false, true]) {
    testWidgets(
      'image test ignores late failure after disposal throws=$throws',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'aicove.ui_models.v1': jsonEncode({'image_generation_enabled': true}),
        });
        final result = Completer<String?>();
        late DeferredImagePlugin plugin;
        await tester.binding.setSurfaceSize(const Size(1000, 1200));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              pluginManagerProvider.overrideWith((ref) {
                plugin = DeferredImagePlugin(ref, result);
                return PluginManager()..register(plugin);
              }),
            ],
            child: const MaterialApp(home: ImageGenerationTestPage()),
          ),
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(ImageGenerationTestPage)),
        );
        await container.read(appSettingsProvider.future);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('开始测试'));
        await tester.tap(find.text('开始测试'));
        await tester.pump();
        expect(plugin.calls, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const MaterialApp(home: Scaffold()));
        if (throws) {
          result.completeError(StateError('synthetic generation failure'));
        } else {
          result.complete(
            jsonEncode({
              'success': false,
              'error': 'synthetic generation failure',
            }),
          );
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
}

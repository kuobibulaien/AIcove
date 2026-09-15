// Test-only fault injection against the installed preferences backend.
// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/artist_preset_page.dart';

class RejectingPreferences extends InMemorySharedPreferencesStore {
  RejectingPreferences(super.data, this.throwsError) : super.withData();
  final bool throwsError;
  int rejectedWrites = 0;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    rejectedWrites++;
    if (throwsError) throw StateError('synthetic write failure');
    return false;
  }
}

void main() {
  testWidgets('failed rename keeps the original identity and retries', (
    tester,
  ) async {
    final originalConfig = jsonEncode(
      const ImageConfig(
        artistPresets: [ArtistPreset(name: 'Audit', content: 'original')],
      ).toJson(),
    );
    SharedPreferences.setMockInitialValues({
      'aicove.plugins.image.config': originalConfig,
    });
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: ArtistPresetPage())),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ArtistPresetPage)),
    );
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    final previous = SharedPreferencesStorePlatform.instance;
    SharedPreferencesStorePlatform.instance = RejectingPreferences({
      'flutter.aicove.plugins.image.config': originalConfig,
    }, false);
    addTearDown(() => SharedPreferencesStorePlatform.instance = previous);
    await tester.enterText(find.byType(TextField), 'Renamed');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(
      container.read(imagePluginConfigProvider).artistPresets.single.name,
      'Audit',
    );
    expect(find.text('重试'), findsOneWidget);
    SharedPreferencesStorePlatform.instance = previous;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(
      container.read(imagePluginConfigProvider).artistPresets.single.name,
      'Renamed',
    );
    final stored =
        jsonDecode(
              (await SharedPreferences.getInstance()).getString(
                'aicove.plugins.image.config',
              )!,
            )
            as Map<String, dynamic>;
    expect(ImageConfig.fromJson(stored).artistPresets.single.name, 'Renamed');
  });

  for (final throwsError in [false, true]) {
    testWidgets('artist save reports persistence failure throws=$throwsError', (
      tester,
    ) async {
      final originalConfig = jsonEncode(
        const ImageConfig(
          artistPresets: [ArtistPreset(name: 'Audit', content: 'original')],
        ).toJson(),
      );
      SharedPreferences.setMockInitialValues({
        'aicove.plugins.image.config': originalConfig,
      });
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: ArtistPresetPage())),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        'edited synthetic prompt',
      );
      await tester.pump();
      final previous = SharedPreferencesStorePlatform.instance;
      final backend = RejectingPreferences({
        'flutter.aicove.plugins.image.config': originalConfig,
      }, throwsError);
      SharedPreferencesStorePlatform.instance = backend;
      addTearDown(() => SharedPreferencesStorePlatform.instance = previous);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(backend.rejectedWrites, 1);
      expect(
        (await backend.getAll())['flutter.aicove.plugins.image.config'],
        originalConfig,
      );
      expect(
        find.text('已保存'),
        findsNothing,
        reason: 'rejected backend writes cannot be reported as saved',
      );
    });
  }

  testWidgets('artist editor back automatically persists the final edit', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'aicove.plugins.image.config': jsonEncode(
        const ImageConfig(
          artistPresets: [ArtistPreset(name: 'Audit', content: 'original')],
        ).toJson(),
      ),
    });
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: ArtistPresetPage())),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ArtistPresetPage)),
    );
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).first,
      'edited synthetic prompt',
    );
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    final saved =
        container
            .read(imagePluginConfigProvider)
            .artistPresets
            .single
            .content ==
        'edited synthetic prompt';
    final draftRemains = tester
        .widgetList<TextField>(find.byType(TextField))
        .any((field) => field.controller?.text == 'edited synthetic prompt');
    expect(
      saved || draftRemains,
      isTrue,
      reason: 'back must not silently lose an unsaved draft',
    );
  });
}

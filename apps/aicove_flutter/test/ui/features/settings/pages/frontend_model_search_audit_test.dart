import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/settings/widgets/model_search_sheet.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/list/moe_settings_row.dart';
import '../../../../helpers/release_source_preview.dart';

Future<ProviderContainer> openSearch(
  WidgetTester tester, {
  bool duplicate = false,
  GlobalKey? previewKey,
}) async {
  SharedPreferences.setMockInitialValues({
    'aicove.ui_models.v1': jsonEncode({
      'providers': [
        for (final id in ['audit-a', if (duplicate) 'audit-b'])
          {
            'id': id,
            'displayName': id,
            'apiKeys': <String>[],
            'apiBaseUrl': 'https://example.invalid/v1',
            'enabled': true,
            'models': ['shared', 'keeper'],
            'visible_models': ['shared', 'keeper'],
            'hidden_models': <String>[],
            'capabilities': ['chat'],
          },
      ],
      'visible_models': ['audit-a:shared', if (duplicate) 'audit-b:shared'],
      'default_model': 'audit-a:keeper',
      'default_chat_models': ['audit-a:keeper'],
      'model_display_names': {'audit-a:shared': 'Distinctive Alias'},
    }),
  });
  final app = ProviderScope(
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        fontFamily: captureReleaseSourcePreview ? 'ReleasePreview' : null,
      ),
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) => TextButton(
            onPressed: () => showModelSearchSheet(context, ref),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpWidget(
    previewKey == null ? app : RepaintBoundary(key: previewKey, child: app),
  );
  final container = ProviderScope.containerOf(
    tester.element(find.byType(Consumer)),
  );
  await container.read(appSettingsProvider.future);
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), 'shared');
  await tester.pumpAndSettle();
  return container;
}

void main() {
  for (final width in [360.0, 1000.0]) {
    testWidgets(
      'search isolates provider visibility and aliases width=$width',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 900);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await loadReleasePreviewFonts(tester);
        final key = GlobalKey();
        final container = await openSearch(
          tester,
          duplicate: true,
          previewKey: key,
        );
        expect(find.byType(MoeSettingsRow), findsNWidgets(2));

        final providerB = find.byWidgetPredicate(
          (widget) =>
              widget is MoeSettingsRow && widget.subtitle == ' · audit-b',
        );
        expect(providerB, findsOneWidget);
        await tester.tap(providerB);
        await tester.pumpAndSettle();
        final settings = container.read(appSettingsProvider).requireValue;
        expect(
          settings.getProvider('audit-a')!.visibleModels,
          contains('shared'),
        );
        expect(
          settings.getProvider('audit-b')!.visibleModels,
          isNot(contains('shared')),
        );
        expect(tester.widget<MoeSettingsRow>(providerB).switchValue, isFalse);
        expect(tester.takeException(), isNull);
        await saveReleaseSourcePreview(
          tester,
          key,
          'model-search-${width.toInt()}',
        );

        final coldContainer = ProviderContainer();
        addTearDown(coldContainer.dispose);
        final restored = await coldContainer.read(appSettingsProvider.future);
        expect(
          restored.getProvider('audit-a')!.visibleModels,
          contains('shared'),
        );
        expect(
          restored.getProvider('audit-b')!.visibleModels,
          isNot(contains('shared')),
        );

        await tester.enterText(find.byType(TextField), 'Distinctive Alias');
        await tester.pumpAndSettle();
        expect(find.byType(MoeSettingsRow), findsOneWidget);
        expect(
          tester.widget<MoeSettingsRow>(find.byType(MoeSettingsRow)).subtitle,
          'Distinctive Alias · audit-a',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('model search preserves same model from distinct providers', (
    tester,
  ) async {
    await openSearch(tester, duplicate: true);
    expect(
      find.descendant(
        of: find.byType(MoeSettingsRow),
        matching: find.text('shared'),
      ),
      findsNWidgets(2),
    );
  });
  testWidgets('model search matches provider qualified display names', (
    tester,
  ) async {
    final container = await openSearch(tester);
    expect(
      container
          .read(appSettingsProvider)
          .requireValue
          .getModelDisplayName('audit-a:shared'),
      'Distinctive Alias',
    );
    await tester.enterText(find.byType(TextField), 'Distinctive Alias');
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(MoeSettingsRow),
        matching: find.text('shared'),
      ),
      findsOneWidget,
    );
  });
  testWidgets('model search refreshes visibility after accepted change', (
    tester,
  ) async {
    final container = await openSearch(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(MoeSettingsRow),
        matching: find.text('shared'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      container
          .read(appSettingsProvider)
          .requireValue
          .getProvider('audit-a')!
          .visibleModels,
      isNot(contains('shared')),
    );
    final row = tester.widget<MoeSettingsRow>(find.byType(MoeSettingsRow));
    expect(
      row.switchValue,
      isFalse,
      reason: 'visible state must track the committed provider value',
    );
  });
}

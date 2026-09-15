import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/settings/widgets/model_search_sheet.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/list/moe_settings_row.dart';

Future<ProviderContainer> openSearch(WidgetTester tester,
    {bool duplicate = false}) async {
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
          }
      ],
      'visible_models': ['audit-a:shared', if (duplicate) 'audit-b:shared'],
      'default_model': 'audit-a:keeper',
      'default_chat_models': ['audit-a:keeper'],
      'model_display_names': {'audit-a:shared': 'Distinctive Alias'},
    })
  });
  await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
          home: Scaffold(
              body: Consumer(
                  builder: (context, ref, _) => TextButton(
                        onPressed: () => showModelSearchSheet(context, ref),
                        child: const Text('open'),
                      ))))));
  final container =
      ProviderScope.containerOf(tester.element(find.byType(Consumer)));
  await container.read(appSettingsProvider.future);
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), 'shared');
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('model search preserves same model from distinct providers',
      (tester) async {
    await openSearch(tester, duplicate: true);
    expect(
        find.descendant(
            of: find.byType(MoeSettingsRow), matching: find.text('shared')),
        findsNWidgets(2));
  });
  testWidgets('model search matches provider qualified display names',
      (tester) async {
    final container = await openSearch(tester);
    expect(
        container
            .read(appSettingsProvider)
            .requireValue
            .getModelDisplayName('audit-a:shared'),
        'Distinctive Alias');
    await tester.enterText(find.byType(TextField), 'Distinctive Alias');
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: find.byType(MoeSettingsRow), matching: find.text('shared')),
        findsOneWidget);
  });
  testWidgets('model search refreshes visibility after accepted change',
      (tester) async {
    final container = await openSearch(tester);
    await tester.tap(find.descendant(
        of: find.byType(MoeSettingsRow), matching: find.text('shared')));
    await tester.pumpAndSettle();
    expect(
        container
            .read(appSettingsProvider)
            .requireValue
            .getProvider('audit-a')!
            .visibleModels,
        isNot(contains('shared')));
    final row = tester.widget<MoeSettingsRow>(find.byType(MoeSettingsRow));
    expect(row.switchValue, isFalse,
        reason: 'visible state must track the committed provider value');
  });
}

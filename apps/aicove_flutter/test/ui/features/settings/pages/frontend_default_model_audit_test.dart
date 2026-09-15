import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/default_model_settings_page.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/form/moe_checkbox.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/list/moe_settings_row.dart';

void main() {
  testWidgets('default model checkbox reflects normalized saved selection',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'aicove.ui_models.v1': jsonEncode({
        'providers': [
          {
            'id': 'audit',
            'displayName': 'Synthetic provider',
            'apiKeys': <String>[],
            'apiBaseUrl': 'https://example.invalid/v1',
            'enabled': true,
            'models': ['only'],
            'visible_models': ['only'],
            'hidden_models': <String>[],
            'capabilities': ['chat'],
          }
        ],
        'visible_models': ['audit:only'],
        'default_model': 'audit:only',
        'default_chat_models': ['audit:only'],
      })
    });
    await tester.pumpWidget(const ProviderScope(
        child: MaterialApp(home: DefaultModelSettingsPage())));
    final container = ProviderScope.containerOf(
        tester.element(find.byType(DefaultModelSettingsPage)));
    await container.read(appSettingsProvider.future);
    await tester.pumpAndSettle();
    final row = find
        .byWidgetPredicate(
            (widget) => widget is MoeSettingsRow && widget.label == 'only')
        .first;
    final checkbox =
        find.descendant(of: row, matching: find.byType(MoeCheckbox));
    expect(tester.widget<MoeCheckbox>(checkbox).value, isTrue);
    await tester.tap(find.descendant(of: row, matching: find.text('only')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final actual =
        container.read(appSettingsProvider).requireValue.defaultChatModels;
    expect(actual, contains('audit:only'),
        reason: 'the settings layer retains a fallback model');
    expect(tester.widget<MoeCheckbox>(checkbox).value,
        actual.contains('audit:only'),
        reason:
            'the displayed selection must agree with the effective saved setting');
  });
}

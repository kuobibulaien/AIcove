import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/default_model_settings_page.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/form/moe_checkbox.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/list/moe_settings_row.dart';
import '../../../../helpers/release_source_preview.dart';

void _seedDefaultSettings() {
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
        },
      ],
      'visible_models': ['audit:only'],
      'default_model': 'audit:only',
      'default_chat_models': ['audit:only'],
    }),
  });
}

class _ControlledDefaultSettings extends AppSettingsNotifier {
  _ControlledDefaultSettings(this.initial, {this.reject = false});
  final AppSettings initial;
  final bool reject;
  final done = Completer<void>();
  final requests = <List<String>>[];

  @override
  Future<AppSettings> build() async => initial;

  @override
  Future<void> setDefaultChatModels(List<String> models) async {
    requests.add(List.of(models));
    await done.future;
    if (reject) throw StateError('synthetic save failure');
    state = AsyncData(
      initial.copyWith(
        defaultChatModels: models.isEmpty ? initial.defaultChatModels : models,
      ),
    );
  }
}

Future<_ControlledDefaultSettings> _openControlled(
  WidgetTester tester, {
  bool reject = false,
}) async {
  _seedDefaultSettings();
  final bootstrap = ProviderContainer();
  final AppSettings initial;
  try {
    initial = await bootstrap.read(appSettingsProvider.future);
  } finally {
    bootstrap.dispose();
  }
  final notifier = _ControlledDefaultSettings(initial, reject: reject);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appSettingsProvider.overrideWith(() => notifier)],
      child: const MaterialApp(home: DefaultModelSettingsPage()),
    ),
  );
  final container = ProviderScope.containerOf(
    tester.element(find.byType(DefaultModelSettingsPage)),
  );
  await container.read(appSettingsProvider.future);
  await tester.pumpAndSettle();
  return notifier;
}

Finder _onlyModelRow() => find.byWidgetPredicate(
  (widget) => widget is MoeSettingsRow && widget.label == 'only',
);

void main() {
  testWidgets('default model checkbox reflects normalized saved selection', (
    tester,
  ) async {
    _seedDefaultSettings();
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: DefaultModelSettingsPage())),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DefaultModelSettingsPage)),
    );
    await container.read(appSettingsProvider.future);
    await tester.pumpAndSettle();
    final row = find
        .byWidgetPredicate(
          (widget) => widget is MoeSettingsRow && widget.label == 'only',
        )
        .first;
    final checkbox = find.descendant(
      of: row,
      matching: find.byType(MoeCheckbox),
    );
    expect(tester.widget<MoeCheckbox>(checkbox).value, isTrue);
    await tester.tap(find.descendant(of: row, matching: find.text('only')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final actual = container
        .read(appSettingsProvider)
        .requireValue
        .defaultChatModels;
    expect(
      actual,
      contains('audit:only'),
      reason: 'the settings layer retains a fallback model',
    );
    expect(
      tester.widget<MoeCheckbox>(checkbox).value,
      actual.contains('audit:only'),
      reason:
          'the displayed selection must agree with the effective saved setting',
    );
  });

  testWidgets('pending default model save ignores stale duplicate callbacks', (
    tester,
  ) async {
    final notifier = await _openControlled(tester);
    final row = _onlyModelRow();
    final oldCheckbox = tester.widget<MoeCheckbox>(
      find.descendant(of: row, matching: find.byType(MoeCheckbox)),
    );
    await tester.tap(find.descendant(of: row, matching: find.text('only')));
    await tester.pump();
    oldCheckbox.onChanged!(true);
    expect(notifier.requests, hasLength(1));
    expect(tester.widget<MoeSettingsRow>(row).enabled, isFalse);
    notifier.done.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<MoeSettingsRow>(row).enabled, isTrue);
    expect(
      tester
          .widget<MoeCheckbox>(
            find.descendant(of: row, matching: find.byType(MoeCheckbox)),
          )
          .value,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed default model save restores selection and reports failure',
    (tester) async {
      final notifier = await _openControlled(tester, reject: true);
      final row = _onlyModelRow();
      await tester.tap(find.descendant(of: row, matching: find.text('only')));
      await tester.pump();
      notifier.done.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('保存默认模型失败'), findsOneWidget);
      expect(
        tester
            .widget<MoeCheckbox>(
              find.descendant(of: row, matching: find.byType(MoeCheckbox)),
            )
            .value,
        isTrue,
      );
      expect(tester.widget<MoeSettingsRow>(row).enabled, isTrue);
      await tester.pump(const Duration(seconds: 4));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('default model save may finish after leaving its page', (
    tester,
  ) async {
    final notifier = await _openControlled(tester);
    await tester.tap(
      find.descendant(of: _onlyModelRow(), matching: find.text('only')),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    notifier.done.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final width in [360.0, 1000.0]) {
    testWidgets('default selection matches cold storage width=$width', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      _seedDefaultSettings();
      await loadReleasePreviewFonts(tester);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: ProviderScope(
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                fontFamily: captureReleaseSourcePreview
                    ? 'ReleasePreview'
                    : null,
              ),
              home: const DefaultModelSettingsPage(),
            ),
          ),
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DefaultModelSettingsPage)),
      );
      await container.read(appSettingsProvider.future);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: _onlyModelRow(), matching: find.text('only')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<MoeCheckbox>(
              find.descendant(
                of: _onlyModelRow(),
                matching: find.byType(MoeCheckbox),
              ),
            )
            .value,
        isTrue,
      );
      final cold = ProviderContainer();
      addTearDown(cold.dispose);
      final stored = await cold.read(appSettingsProvider.future);
      expect(stored.defaultChatModels, ['audit:only']);
      expect(tester.takeException(), isNull);
      await saveReleaseSourcePreview(
        tester,
        key,
        'default-model-${width.toInt()}',
      );
    });
  }
}

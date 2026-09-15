import 'dart:async';
import 'dart:convert';
import 'package:aicove_flutter/src/features/settings/provider_detail/provider_detail_support.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/settings/provider_detail/provider_detail_actions.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/provider_detail_page.dart';

class DeferredActions extends ProviderDetailActions {
  DeferredActions(super.ref);
  final result = Completer<String>();
  int requests = 0;
  final savedNames = <String>[];
  @override
  Future<void> autoSaveProvider(
      {required ProviderAuth provider,
      required String displayName,
      required String apiBaseUrl,
      required String apiPath,
      required String apiKey}) async {
    savedNames.add(displayName);
  }

  @override
  Future<String> testModel(
      {required ProviderAuth provider,
      required String apiKey,
      required String modelId}) {
    requests++;
    return result.future;
  }
}

void main() {
  testWidgets('key test completion preserves newer enabled edit',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        {'aicove.ui_models.v1': jsonEncode(_mockStore)});
    late DeferredActions actions;
    await tester.pumpWidget(ProviderScope(
        overrides: [
          providerDetailActionsProvider
              .overrideWith((ref) => actions = DeferredActions(ref)),
        ],
        child: const MaterialApp(
            home: MultiKeyManagerPage(providerId: 'openai'))));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
        tester.element(find.byType(MultiKeyManagerPage)));
    bool enabled() => providerMultiKeyItemsFromProvider(container
            .read(appSettingsProvider)
            .requireValue
            .getProvider('openai')!)
        .single
        .enabled;
    await tester.tap(find.byElementPredicate((element) =>
        element.widget is Tooltip &&
        (element.widget as Tooltip).message == '检测' &&
        element.findAncestorWidgetOfExactType<MoeAppBar>() == null));
    await tester.pump();
    expect(actions.requests, 1);
    await tester.tap(find.byType(MoeSwitch));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(enabled(), false,
        reason: 'user edit must be committed before late completion');
    actions.result.complete('ok');
    await tester.pumpAndSettle();
    expect(enabled(), false,
        reason: 'late status update must preserve the newer enabled flag');
  });

  testWidgets('batch key detection stops after leaving page', (tester) async {
    final store = jsonDecode(jsonEncode(_mockStore)) as Map<String, dynamic>;
    final provider = (store['providers'] as List).first;
    final items = provider['custom_config']['multi_key_items'] as List;
    items.add({
      ...items.first as Map<String, dynamic>,
      'id': 'mk_2',
      'key': 'synthetic-2'
    });
    SharedPreferences.setMockInitialValues(
        {'aicove.ui_models.v1': jsonEncode(store)});
    late DeferredActions actions;
    await tester.pumpWidget(ProviderScope(
        overrides: [
          providerDetailActionsProvider
              .overrideWith((ref) => actions = DeferredActions(ref)),
        ],
        child: const MaterialApp(
            home: MultiKeyManagerPage(providerId: 'openai'))));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(MoeAppBar), matching: find.byTooltip('检测')));
    await tester.pump();
    expect(actions.requests, 1);
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    actions.result.complete('ok');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    expect(actions.requests, 1);
  });

  for (final waitForSave in [false, true]) {
    testWidgets('provider edit survives back wait=$waitForSave',
        (tester) async {
      SharedPreferences.setMockInitialValues(
          {'aicove.ui_models.v1': jsonEncode(_mockStore)});
      late DeferredActions actions;
      await tester.pumpWidget(ProviderScope(
          overrides: [
            providerDetailActionsProvider
                .overrideWith((ref) => actions = DeferredActions(ref)),
          ],
          child: MaterialApp(
              home: Builder(
                  builder: (context) => Scaffold(
                          body: TextButton(
                        onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                                builder: (_) => const ProviderDetailPage(
                                    providerId: 'openai'))),
                        child: const Text('open'),
                      ))))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Renamed provider');
      if (waitForSave) await tester.pump(const Duration(milliseconds: 750));
      Navigator.of(tester.element(find.byType(ProviderDetailPage))).maybePop();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      expect(actions.savedNames, contains('Renamed provider'));
    });
  }

  testWidgets('closing model test sheet ignores late result', (tester) async {
    SharedPreferences.setMockInitialValues(
        {'aicove.ui_models.v1': jsonEncode(_mockStore)});
    late DeferredActions actions;
    await tester.pumpWidget(ProviderScope(
        overrides: [
          providerDetailActionsProvider
              .overrideWith((ref) => actions = DeferredActions(ref)),
        ],
        child:
            const MaterialApp(home: ProviderDetailPage(providerId: 'openai'))));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('测试模型'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部测试'));
    await tester.pump();
    expect(actions.requests, 1);
    Navigator.of(tester.element(find.text('全部测试'))).pop();
    await tester.pumpAndSettle();
    actions.result.complete('ok');
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

const _mockStore = <String, dynamic>{
  'providers': [
    {
      'id': 'openai',
      'displayName': 'OpenAI',
      'apiKeys': <String>['sk-test-1'],
      'apiBaseUrl': 'https://api.example.com/v1',
      'enabled': true,
      'models': <String>['gpt-4o-mini'],
      'visible_models': <String>['gpt-4o-mini'],
      'hidden_models': <String>[],
      'capabilities': <String>['chat'],
      'custom_config': <String, dynamic>{
        'requestFormat': 'openai',
        'multi_key_enabled': true,
        'multi_key_strategy': 'round_robin',
        'multi_key_items': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'mk_1',
            'key': 'sk-test-1',
            'alias': '主 Key',
            'enabled': true,
            'status': 'normal',
            'updated_at': 1,
          },
        ],
        'multi_key_rr_index': 0,
      },
    },
  ],
  'visible_models': <String>['gpt-4o-mini'],
  'default_model': 'openai:gpt-4o-mini',
  'default_chat_models': <String>['openai:gpt-4o-mini'],
  'model_display_names': <String, String>{
    'openai:gpt-4o-mini': 'GPT-4o mini',
  },
};

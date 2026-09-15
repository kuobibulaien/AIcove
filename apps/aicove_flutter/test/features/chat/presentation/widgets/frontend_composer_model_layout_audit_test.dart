import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/composer_model_picker_sheet.dart';

void main() {
  for (final size in [const Size(320, 568), const Size(1000, 768)]) {
    for (final scale in [1.2, 1.8]) {
      for (final queueAll in [false, true]) {
        testWidgets('model picker size=$size scale=$scale queueAll=$queueAll',
            (tester) async {
          final models = List.generate(100, (i) => 'synthetic-model-$i');
          final refs = models.map((model) => 'audit:$model').toList();
          SharedPreferences.setMockInitialValues({
            'aicove.ui_models.v1': jsonEncode({
              'providers': [
                {
                  'id': 'audit',
                  'displayName': 'Synthetic provider',
                  'apiKeys': <String>[],
                  'apiBaseUrl': 'https://example.invalid/v1',
                  'enabled': true,
                  'models': models,
                  'visible_models': models,
                  'hidden_models': <String>[],
                  'capabilities': ['chat'],
                }
              ],
              'visible_models': refs,
              'default_model': refs.first,
              'default_chat_models': queueAll ? refs : [refs.first],
            }),
          });
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          String? selected;
          await tester.pumpWidget(ProviderScope(
              child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
                body: Builder(
                    builder: (context) => TextButton(
                          onPressed: () async {
                            selected =
                                await showComposerModelPickerSheet(context);
                          },
                          child: const Text('open'),
                        ))),
          )));
          await tester.pumpAndSettle();
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('默认队列'), findsOneWidget);
          final target = find
              .byKey(ValueKey('${queueAll ? 'queue' : 'other'}_${refs.last}'));
          await tester.ensureVisible(target);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.tap(target);
          await tester.pumpAndSettle();
          expect(selected, refs.last);
        });
      }
    }
  }
}

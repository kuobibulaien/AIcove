import 'dart:async';

import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('opening and focus changes do not write; edits debounce',
      (tester) async {
    final text = TextEditingController(text: 'original');
    final saves = <String>[];
    final save = MoeAutoSaveController()
      ..configure(
          fields: [text],
          snapshot: () => text.text,
          save: () async => saves.add(text.text));
    text.selection = const TextSelection.collapsed(offset: 2);
    await tester.pump(const Duration(seconds: 1));
    expect(saves, isEmpty);
    text.text = 'first';
    await tester.pump(const Duration(milliseconds: 200));
    text.text = 'last';
    await tester.pump(const Duration(milliseconds: 449));
    expect(saves, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(saves, ['last']);
    expect(save.pending, isFalse);
    save.dispose();
    text.dispose();
  });

  testWidgets(
      'writes serialize and flush includes edits arriving during a write',
      (tester) async {
    final text = TextEditingController(text: 'original');
    final first = Completer<void>();
    final saves = <String>[];
    final save = MoeAutoSaveController()
      ..configure(
          fields: [text],
          snapshot: () => text.text,
          save: () async {
            final value = text.text;
            if (value == 'first') await first.future;
            saves.add(value);
          });
    text.text = 'first';
    final flushing = save.flush();
    text.text = 'last';
    await tester.pump(const Duration(seconds: 1));
    expect(saves, isEmpty);
    first.complete();
    expect(await flushing, isTrue);
    expect(saves, ['first', 'last']);
    save.dispose();
    text.dispose();
  });

  testWidgets('failure retains pending edit and retry persists it',
      (tester) async {
    var text = 'old';
    var fail = true;
    var persisted = 'old';
    final save = MoeAutoSaveController()
      ..configure(
          snapshot: () => text,
          save: () async {
            if (fail) throw StateError('disk full');
            persisted = text;
          });
    text = 'new';
    save.changed();
    expect(await save.flush(), isFalse);
    expect(persisted, 'old');
    expect(save.pending, isTrue);
    expect(save.error, isA<StateError>());
    fail = false;
    expect(await save.flush(), isTrue);
    expect(persisted, 'new');
    expect(save.error, isNull);
    save.dispose();
  });

  testWidgets('newer edit is retried when an in-flight write fails',
      (tester) async {
    var draft = 'old';
    var persisted = 'old';
    final first = Completer<void>();
    final save = MoeAutoSaveController()
      ..configure(
          snapshot: () => draft,
          save: () async {
            final value = draft;
            if (value == 'first') await first.future;
            persisted = value;
          });
    draft = 'first';
    save.changed();
    final flushing = save.flush();
    draft = 'last';
    save.changed();
    await tester.pump(const Duration(seconds: 1));
    first.completeError(StateError('first write failed'));
    expect(await flushing, isTrue);
    expect(persisted, 'last');
    expect(save.error, isNull);
    save.dispose();
  });

  testWidgets('IME composition is not persisted until committed',
      (tester) async {
    final text = TextEditingController();
    final saves = <String>[];
    final save = MoeAutoSaveController()
      ..configure(
          fields: [text],
          snapshot: () => text.text,
          save: () async => saves.add(text.text));
    text.value = const TextEditingValue(
        text: 'ni', composing: TextRange(start: 0, end: 2));
    await tester.pump(const Duration(seconds: 1));
    expect(await save.flush(), isFalse);
    expect(saves, isEmpty);
    text.value = const TextEditingValue(text: '你');
    await tester.pump(const Duration(seconds: 1));
    expect(saves, ['你']);
    save.dispose();
    text.dispose();
  });

  for (final width in [360.0, 1000.0]) {
    testWidgets('back flushes final text without confirmation at $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var persisted = 'old';
      final text = TextEditingController(text: persisted);
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                      body: TextButton(
                    child: const Text('open'),
                    onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => MoeAutoSaveForm(
                              fields: [text],
                              snapshot: () => text.text,
                              save: () async => persisted = text.text,
                              builder: (context, update) => Scaffold(
                                  appBar: const MoeAppBar(
                                      title: 'edit', showBackButton: true),
                                  body: TextField(controller: text))),
                        )),
                  )))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'last keystroke');
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(persisted, 'last keystroke');
      expect(find.text('open'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      text.dispose();
    });
  }

  testWidgets(
      'sheet close waits for write and failure leaves editable form with retry',
      (tester) async {
    var fail = true;
    var persisted = 'old';
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                    body: TextButton(
                  child: const Text('open'),
                  onPressed: () => showMoeAutoSaveTextEditor(
                      context: context,
                      title: 'edit',
                      initialValue: persisted,
                      onSave: (text) async {
                        if (fail) throw StateError('disk full');
                        persisted = text;
                      }),
                )))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'new');
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('new'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(persisted, 'old');
    fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(persisted, 'new');
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('edit'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

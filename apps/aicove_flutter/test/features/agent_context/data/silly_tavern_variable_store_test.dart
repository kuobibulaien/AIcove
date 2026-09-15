import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_variable_store.dart';

void main() {
  late Directory tempDirectory;
  late SillyTavernVariableStore store;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('st_variables_');
    store = SillyTavernVariableStore(
      documentsDirectoryResolver: () async => tempDirectory,
    );
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('persists values and skips unchanged writes', () async {
    const presetId = 'st_preset_aaaaaaaaaaaaaaaaaaaaaaaa';
    final firstWrite = await store.saveIfChanged(
      presetId: presetId,
      conversationId: 'conversation-a',
      previousValues: const <String, String>{},
      values: const <String, String>{'mode': 'story'},
    );
    final snapshot = await store.load(
      presetId: presetId,
      conversationId: 'conversation-a',
    );
    final secondWrite = await store.saveIfChanged(
      presetId: presetId,
      conversationId: 'conversation-a',
      previousValues: snapshot.values,
      values: const <String, String>{'mode': 'story'},
    );

    expect(firstWrite, isTrue);
    expect(secondWrite, isFalse);
    expect(snapshot.values, <String, String>{'mode': 'story'});
  });

  test('isolates values by conversation and preset', () async {
    await store.saveIfChanged(
      presetId: 'st_preset_aaaaaaaaaaaaaaaaaaaaaaaa',
      conversationId: 'conversation-a',
      previousValues: const <String, String>{},
      values: const <String, String>{'value': 'a'},
    );
    await store.saveIfChanged(
      presetId: 'st_preset_aaaaaaaaaaaaaaaaaaaaaaaa',
      conversationId: 'conversation-b',
      previousValues: const <String, String>{},
      values: const <String, String>{'value': 'b'},
    );
    await store.saveIfChanged(
      presetId: 'st_preset_bbbbbbbbbbbbbbbbbbbbbbbb',
      conversationId: 'conversation-a',
      previousValues: const <String, String>{},
      values: const <String, String>{'value': 'other-preset'},
    );

    expect(
      (await store.load(
        presetId: 'st_preset_aaaaaaaaaaaaaaaaaaaaaaaa',
        conversationId: 'conversation-a',
      )).values['value'],
      'a',
    );
    expect(
      (await store.load(
        presetId: 'st_preset_aaaaaaaaaaaaaaaaaaaaaaaa',
        conversationId: 'conversation-b',
      )).values['value'],
      'b',
    );
    expect(
      (await store.load(
        presetId: 'st_preset_bbbbbbbbbbbbbbbbbbbbbbbb',
        conversationId: 'conversation-a',
      )).values['value'],
      'other-preset',
    );
  });

  test('corrupt snapshot falls back to empty variables with warning', () async {
    const presetId = 'st_preset_aaaaaaaaaaaaaaaaaaaaaaaa';
    await store.saveIfChanged(
      presetId: presetId,
      conversationId: 'conversation-a',
      previousValues: const <String, String>{},
      values: const <String, String>{'value': 'ok'},
    );
    final files = await tempDirectory
        .list(recursive: true)
        .where((entity) => entity is File && entity.path.endsWith('.json'))
        .cast<File>()
        .toList();
    await files.single.writeAsString(
      jsonEncode(<String, dynamic>{'bad': true}),
    );

    final snapshot = await store.load(
      presetId: presetId,
      conversationId: 'conversation-a',
    );

    expect(snapshot.values, isEmpty);
    expect(snapshot.warnings, isNotEmpty);
  });
}

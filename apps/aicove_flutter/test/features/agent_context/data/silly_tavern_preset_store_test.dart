import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_preset_store.dart';

void main() {
  test(
    'imports atomically and round-trips raw preset with stable id',
    () async {
      final temp = await Directory.systemTemp.createTemp('aicove_st_store_');
      addTearDown(() async {
        if (await temp.exists()) await temp.delete(recursive: true);
      });
      final store = SillyTavernPresetStore(
        documentsDirectoryResolver: () async => temp,
      );
      const source = '''
{
  "name":"Round Trip",
  "prompts":[
    {"identifier":"main","role":"system","content":"hello"},
    {"identifier":"chatHistory","marker":true}
  ],
  "prompt_order":[{"order":[
    {"identifier":"main","enabled":true},
    {"identifier":"chatHistory","enabled":true}
  ]}]
}
''';

      final imported = await store.importSource(
        source,
        sourceFileName: 'round-trip.json',
      );
      final importedAgain = await store.importSource(
        source,
        sourceFileName: 'renamed.json',
      );
      final loaded = await store.get(imported.id);
      final listed = await store.list();

      expect(importedAgain.id, imported.id);
      expect(loaded?.name, 'Round Trip');
      expect(loaded?.rawPreset['prompts'], isA<List>());
      expect(listed.map((preset) => preset.id), <String>[imported.id]);
      final files = await Directory(
        '${temp.path}/aicove/sillytavern_presets',
      ).list().toList();
      expect(files.whereType<File>(), hasLength(1));
      expect(files.single.path, endsWith('${imported.id}.json'));
    },
  );

  test('missing or malformed ids return null for runtime fallback', () async {
    final temp = await Directory.systemTemp.createTemp('aicove_st_missing_');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    final store = SillyTavernPresetStore(
      documentsDirectoryResolver: () async => temp,
    );

    expect(await store.get('not-a-preset'), isNull);
    expect(await store.get('st_preset_aaaaaaaaaaaaaaaaaaaaaaaa'), isNull);
  });

  test('corrupt stored file is ignored so chat can fall back', () async {
    final temp = await Directory.systemTemp.createTemp('aicove_st_corrupt_');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    final directory = Directory('${temp.path}/aicove/sillytavern_presets');
    await directory.create(recursive: true);
    const id = 'st_preset_bbbbbbbbbbbbbbbbbbbbbbbb';
    await File('${directory.path}/$id.json').writeAsString('{broken');
    final store = SillyTavernPresetStore(
      documentsDirectoryResolver: () async => temp,
    );

    expect(await store.get(id), isNull);
    expect(await store.list(), isEmpty);
  });

  test('regex authorization is persisted and can be revoked', () async {
    final temp = await Directory.systemTemp.createTemp('aicove_st_auth_');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    final store = SillyTavernPresetStore(
      documentsDirectoryResolver: () async => temp,
    );
    const source = '''
{
  "extensions":{"regex_scripts":[{"id":"r1","findRegex":"x","replaceString":"y","placement":[2]}]},
  "prompts":[{"identifier":"chatHistory","marker":true}],
  "prompt_order":[{"order":[{"identifier":"chatHistory","enabled":true}]}]
}
''';

    final imported = await store.importSource(
      source,
      sourceFileName: 'authorized.json',
      regexAuthorized: true,
    );
    expect(imported.regexAuthorized, isTrue);
    expect((await store.get(imported.id))?.regexAuthorized, isTrue);

    expect(await store.setRegexAuthorization(imported.id, false), isTrue);
    expect((await store.get(imported.id))?.regexAuthorized, isFalse);
  });
}

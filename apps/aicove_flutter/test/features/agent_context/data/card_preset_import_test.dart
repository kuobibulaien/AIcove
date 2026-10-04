import 'dart:io';

import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_preset_store.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/tavern_compatibility_port.dart';
import 'package:flutter_test/flutter_test.dart';

const _base = '''{"name":"组合A","prompts":[
{"identifier":"charDescription","marker":true},
{"identifier":"chatHistory","marker":true}],"prompt_order":[
{"identifier":"charDescription","enabled":true},
{"identifier":"chatHistory","enabled":true}],
"extensions":{"regex_scripts":[{"id":"shared","scriptName":"原有","findRegex":"x","replaceString":""}]}}''';

const _hideVars = {
  'id': 'hide-vars',
  'scriptName': '去除变量更新',
  'findRegex': '/<UpdateVariable>[\\s\\S]*?<\\/UpdateVariable>/g',
  'replaceString': '',
  'placement': [2],
  'markdownOnly': true,
  'promptOnly': true,
};

const _book = {
  'name': '卡内世界书',
  'entries': [
    {
      'keys': ['须弥'],
      'content': '雨林之国',
    },
  ],
};

void main() {
  late Directory directory;
  late SillyTavernPresetStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('card_preset_');
    store = SillyTavernPresetStore(
      documentsDirectoryResolver: () async => directory,
    );
  });
  tearDown(() => directory.delete(recursive: true));

  test('copies bound preset with card resources and leaves base untouched',
      () async {
    final base = await store.importSource(
      _base,
      sourceFileName: 'a.json',
      regexAuthorized: false,
    );
    final result = await store.createCardPreset(
      explicitBaseId: base.id,
      name: '纳西妲 专用',
      regexScripts: [
        _hideVars,
        {'id': 'shared', 'findRegex': 'dup'},
        {'scriptName': '缺 find'},
      ],
      characterBook: _book,
      regexAuthorized: true,
    );

    final copy = result.preset;
    expect(copy.id, isNot(base.id));
    expect(copy.id, matches(RegExp(r'^st_preset_[a-f0-9]{24}$')));
    expect(copy.name, '纳西妲 专用');
    expect(copy.regexAuthorized, isTrue);
    expect(copy.regexScripts.map((s) => s.id), containsAll(['shared', 'hide-vars']));
    expect(copy.worldBooks.single.entries.single.content, '雨林之国');
    expect(result.baseName, '组合A');
    expect((result.addedRegexCount, result.skippedRegexCount), (1, 2));
    expect(result.worldEntryCount, 1);
    expect(result.warnings, hasLength(1)); // 没有世界书节点

    final reloaded = (await store.get(copy.id))!;
    expect(reloaded.regexScripts.length, 2);
    expect(reloaded.worldBooks, hasLength(1));
    final untouched = (await store.get(base.id))!;
    expect(untouched.regexScripts.single.id, 'shared');
    expect(untouched.worldBooks, isEmpty);
    expect(untouched.regexAuthorized, isFalse);
  });

  test('two roles from the same base get isolated copies', () async {
    final base = await store.importSource(_base, sourceFileName: 'a.json');
    final a = await store.createCardPreset(
      explicitBaseId: base.id,
      name: 'A 专用',
      regexScripts: const [_hideVars],
      characterBook: null,
    );
    final b = await store.createCardPreset(
      explicitBaseId: base.id,
      name: 'A 专用',
      regexScripts: const [],
      characterBook: _book,
    );
    expect(a.preset.id, isNot(b.preset.id));
    expect((await store.get(b.preset.id))!.regexScripts.single.id, 'shared');
    expect((await store.get(a.preset.id))!.worldBooks, isEmpty);
  });

  test('null authorization inherits base; template base starts unauthorized',
      () async {
    final base = await store.importSource(
      _base,
      sourceFileName: 'a.json',
      regexAuthorized: true,
    );
    final inherited = await store.createCardPreset(
      explicitBaseId: base.id,
      name: '只有世界书',
      regexScripts: const [],
      characterBook: _book,
    );
    expect(inherited.preset.regexAuthorized, isTrue);

    final fromTemplate = await store.createCardPreset(
      explicitBaseId: null,
      name: '无预设',
      regexScripts: const [_hideVars],
      characterBook: _book,
    );
    expect(fromTemplate.baseName, isNull);
    expect(fromTemplate.preset.regexAuthorized, isFalse);
    expect(fromTemplate.warnings, isEmpty);
  });

  test('falls back to default preset, but a broken explicit binding throws',
      () async {
    final base = await store.importSource(_base, sourceFileName: 'a.json');
    await store.savePluginSettings(TavernPluginSettings(defaultPresetId: base.id));
    final viaDefault = await store.createCardPreset(
      explicitBaseId: null,
      name: '默认',
      regexScripts: const [_hideVars],
      characterBook: null,
    );
    expect(viaDefault.baseName, '组合A');

    await expectLater(
      store.createCardPreset(
        explicitBaseId: 'st_preset_000000000000000000000000',
        name: '坏引用',
        regexScripts: const [_hideVars],
        characterBook: null,
      ),
      throwsStateError,
    );
  });
}

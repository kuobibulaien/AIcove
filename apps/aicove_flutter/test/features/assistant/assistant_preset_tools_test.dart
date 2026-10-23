// ADR0073 full access, batch P4: the assistant imports presets and adds
// regex scripts and world books it wrote itself; deleting asks the user.
import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_preset_store.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_cards.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_preset_tools.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_review.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late SillyTavernPresetStore store;
  late ProviderContainer container;
  late AssistantPresetTools tools;
  final downloads = <String>[];
  var boundToHiddenRole = false;

  setUp(() async {
    downloads.clear();
    boundToHiddenRole = false;
    dir = await Directory.systemTemp.createTemp('assistant_presets_');
    store = SillyTavernPresetStore(documentsDirectoryResolver: () async => dir);
    container = ProviderContainer();
    tools = AssistantPresetTools(
      presets: store.list,
      importPreset: (source, name) =>
          store.importSource(source, sourceFileName: name),
      change: (_, action) => action(store),
      deletePreset: (id) async {
        if (boundToHiddenRole) throw StateError('角色「秘密情人」仍在使用此预设');
        await store.deletePreset(id);
      },
      cards: () => container.read(assistantCardsProvider.notifier),
      download: (url) async {
        downloads.add(url);
        return File(
          'test/fixtures/sillytavern/openai_default_shape.json',
        ).readAsString();
      },
    );
  });

  tearDown(() async {
    container.dispose();
    await dir.delete(recursive: true);
  });

  Future<Map<String, dynamic>> run(
    String name,
    Map<String, dynamic> args,
  ) async =>
      jsonDecode(
            (await tools.tools().singleWhere((t) => t.name == name).handler(
              args,
            ))!,
          )
          as Map<String, dynamic>;

  test('imports from a link, then adds its own regex and world book', () async {
    final imported = await run(AssistantPresetTools.importPresetTool, {
      'url': 'https://example.com/presets/default.json',
    });
    expect(imported['ok'], isTrue, reason: '$imported');
    final id = imported['preset_id'] as String;

    final regex = await run(AssistantPresetTools.addRegex, {
      'preset_id': id,
      'scripts': jsonEncode({
        'id': 'strip-thinking',
        'scriptName': '去掉思考',
        'findRegex': '/<think>[\\s\\S]*?<\\/think>/g',
        'replaceString': '',
        'placement': [2],
      }),
    });
    expect(regex['ok'], isTrue, reason: '$regex');

    final book = await run(AssistantPresetTools.addWorldBook, {
      'preset_id': id,
      'name': '须弥',
      'book': jsonEncode({
        'entries': {
          '0': {
            'uid': 0,
            'key': ['须弥'],
            'content': '须弥是智慧之国。',
          },
        },
      }),
    });
    expect(book['ok'], isTrue, reason: '$book');

    final preset = (await store.get(id))!;
    expect(preset.regexScripts.map((s) => s.name), contains('去掉思考'));
    expect(preset.worldBooks.single.entries.single.content, '须弥是智慧之国。');
  });

  test('without a link the import is a card; deleting asks', () async {
    await run(AssistantPresetTools.importPresetTool, {});
    expect(
      container.read(assistantCardsProvider).whereType<AssistantPresetImport>(),
      hasLength(1),
    );
    expect(downloads, isEmpty);
    expect(
      tools.riskOf(AssistantPresetTools.importPresetTool, {}),
      AssistantRisk.readOnly,
    );
    expect(
      tools.riskOf(AssistantPresetTools.deletePresetTool, {}),
      AssistantRisk.major,
    );
  });

  test('a refused delete never names the bound roles', () async {
    final imported = await run(AssistantPresetTools.importPresetTool, {
      'url': 'https://example.com/p.json',
    });
    boundToHiddenRole = true;
    final result = await run(AssistantPresetTools.deletePresetTool, {
      'preset_id': imported['preset_id'],
    });
    expect(result['error'], 'invalid');
    expect(jsonEncode(result), isNot(contains('秘密情人')));
  });
}

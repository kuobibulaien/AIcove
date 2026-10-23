// ADR0073 full access, batch P5: global plugin options change and undo.
import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/features/agent_plugins/file_change_journal.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_plugin_option_tools.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/plugin_prompts.dart';
import 'package:aicove_flutter/src/features/plugins/web_search/web_search_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late FileChangeJournal journal;
  late AssistantPluginOptionTools tools;
  var time = (messageTimestamp: true, currentTime: true);
  var search = const WebSearchConfig();
  var prompts = const PluginPrompts();

  setUp(() async {
    time = (messageTimestamp: true, currentTime: true);
    search = const WebSearchConfig();
    prompts = const PluginPrompts();
    dir = await Directory.systemTemp.createTemp('assistant_options_');
    final options = assistantPluginOptions(
      time: () => time,
      setTime: ({messageTimestamp, currentTime}) async => time = (
        messageTimestamp: messageTimestamp ?? time.messageTimestamp,
        currentTime: currentTime ?? time.currentTime,
      ),
      webSearch: () => search,
      setWebSearch: (config) async => search = config,
      prompts: () => prompts,
      setPrompt: (slot, text) async => prompts = prompts.withText(slot, text),
      setPromptIf: (slot, expected, text) async {
        if (prompts.of(slot) != expected) return false;
        prompts = prompts.withText(slot, text);
        return true;
      },
    );
    journal = FileChangeJournal(
      file: () async => File('${dir.path}/journal.json'),
      appliers: {
        assistantPluginOptionChangeKind: AssistantPluginOptionApplier(
          () => options,
        ),
      },
    );
    tools = AssistantPluginOptionTools(options: options, journal: journal);
  });

  tearDown(() => dir.delete(recursive: true));

  Future<Map<String, dynamic>> set(String key, Object value) async =>
      jsonDecode(
            (await tools.tools()
                .singleWhere(
                  (t) => t.name == AssistantPluginOptionTools.setTool,
                )
                .handler({'key': key, 'value': value}))!,
          )
          as Map<String, dynamic>;

  test('options change, refuse bad values and undo', () async {
    expect((await set('time.current_time', false))['ok'], isTrue);
    expect((await set('web_search.num_results', 8))['ok'], isTrue);
    expect((await set('web_search.num_results', 99))['error'], 'invalid');
    expect(time.currentTime, isFalse);
    expect(search.numResults, 8);

    for (final entry in await journal.recent()) {
      await journal.undo(entry.id);
    }
    expect(time.currentTime, isTrue);
    expect(search.numResults, WebSearchConfig.defaultNumResults);
  });

  test('the sticker prompt changes, resets to default and undoes', () async {
    const fewer = '只在情绪特别强烈时偶尔发一个表情包。可用：{tags}';
    expect((await set('prompt.sticker', fewer))['ok'], isTrue);
    expect(prompts.of(PluginPromptSlot.sticker), fewer);

    // An empty text puts the default back, and undo can tell it is current.
    expect((await set('prompt.sticker', ' '))['ok'], isTrue);
    expect(prompts.isDefault(PluginPromptSlot.sticker), isTrue);
    await journal.undo((await journal.recent(limit: 1)).single.id);
    expect(prompts.of(PluginPromptSlot.sticker), fewer);

    expect((await set('prompt.sticker', 42))['error'], 'invalid');
  });

  test('the default prompt with blanks around it still undoes', () async {
    await set('prompt.sticker', '自定义：{tags}');
    final padded = '  ${PluginPromptSlot.sticker.defaultText}\n';
    expect((await set('prompt.sticker', padded))['ok'], isTrue);
    expect(prompts.isDefault(PluginPromptSlot.sticker), isTrue);
    await journal.undo((await journal.recent(limit: 1)).single.id);
    expect(prompts.of(PluginPromptSlot.sticker), '自定义：{tags}');
  });

  test('a prompt changed by hand meanwhile is not overwritten', () async {
    await set('prompt.sticker', '自定义：{tags}');
    // The user edits the prompt page after the assistant's change.
    prompts = prompts.withText(PluginPromptSlot.sticker, '手写：{tags}');
    await expectLater(
      journal.undo((await journal.recent(limit: 1)).single.id),
      throwsStateError,
    );
    expect(prompts.of(PluginPromptSlot.sticker), '手写：{tags}');
  });
}

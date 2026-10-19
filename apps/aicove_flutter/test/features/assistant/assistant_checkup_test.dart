// ADR0073 T4: the checkup lists the usual setup problems with fixed texts
// and skips the privacy space.
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_preset_parser.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_checkup.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assistant_onboarding_test.dart' show deepSeek, settingsWith;

final _now = DateTime(2026, 10, 17);

Conversation _role(
  String id, {
  List<String>? plugins,
  String? recipeId,
  bool hidden = false,
}) => Conversation(
  id: id,
  title: id,
  displayName: id,
  enabledPlugins: plugins,
  recipeId: recipeId,
  isHidden: hidden,
  createdAt: _now,
  updatedAt: _now,
);

void main() {
  test('finds broken models, presets, plugins and calls', () async {
    final preset = const SillyTavernPresetParser().parseSource(
      r'''
{
  "function_calling": false,
  "prompts": [{"identifier":"main","role":"system","content":"x"}],
  "prompt_order": [{"order":[{"identifier":"main","enabled":true}]}],
  "extensions": {"regex_scripts": [
    {"id":"r1","scriptName":"清理","findRegex":"/a/g","replaceString":"b"}
  ]}
}
''',
      sourceFileName: 'p.json',
      storedId: 'st_preset_aaaaaaaaaaaaaaaaaaaaaaaa',
    );
    final checked = <String>[];
    final checkup = AssistantCheckup(
      settings: () async => settingsWith([
        deepSeek(), // enabled, no key
      ], 'deepseek:deepseek-flash'),
      roles: () async => [
        _role('drawer', plugins: const ['image', 'tts'], recipeId: preset.id),
        _role('lost', recipeId: 'st_preset_bbbbbbbbbbbbbbbbbbbbbbbb'),
        _role('bare', plugins: const []),
        _role('secret', recipeId: 'gone', hidden: true),
      ],
      presets: () async => [preset],
      voiceEnabled: () => true,
      callUnavailable: (role) async {
        checked.add(role.id);
        return '此角色没有可用的音色';
      },
    );

    final findings = await checkup.run();
    String? textOf(String area, [String? roleId]) => findings
        .where((f) => f.area == area && f.roleId == roleId)
        .map((f) => f.text)
        .join('|');

    expect(textOf('model'), contains('默认聊天模型不可用'));
    expect(textOf('provider'), contains('没填 Key'));
    expect(textOf('preset', 'lost'), contains('找不到'));
    expect(textOf('preset', 'drawer'), allOf(contains('绘图'), contains('正则')));
    expect(textOf('plugins', 'bare'), contains('一个插件都没开'));
    expect(textOf('voice_call', 'drawer'), contains('没有可用的音色'));
    expect(findings.where((f) => f.roleId == 'secret'), isEmpty);
    expect(checked, ['drawer', 'lost']);
  });

  test(
    'roles without a binding are checked against the default preset',
    () async {
      final preset = const SillyTavernPresetParser().parseSource(
        r'''
{
  "function_calling": false,
  "prompts": [{"identifier":"main","role":"system","content":"x"}],
  "prompt_order": [{"order":[{"identifier":"main","enabled":true}]}]
}
''',
        sourceFileName: 'p.json',
        storedId: 'st_preset_aaaaaaaaaaaaaaaaaaaaaaaa',
      );
      AssistantCheckup checkup(String? defaultId) => AssistantCheckup(
        settings: () async =>
            settingsWith([deepSeek()], 'deepseek:deepseek-flash'),
        roles: () async => [
          _role('drawer', plugins: const ['image']),
        ],
        presets: () async => [preset],
        defaultPresetId: () async => defaultId,
        voiceEnabled: () => false,
        callUnavailable: (_) async => null,
      );

      final viaDefault = await checkup(preset.id).run();
      expect(
        viaDefault.where((f) => f.roleId == 'drawer').map((f) => f.text),
        contains(allOf(contains('默认预设'), contains('绘图'))),
      );
      final missing = await checkup('st_preset_bbbbbbbbbbbbbbbbbbbbbbbb').run();
      expect(
        missing
            .where((f) => f.area == 'preset' && f.roleId == null)
            .single
            .text,
        contains('默认酒馆预设在本机找不到'),
      );
    },
  );

  test('voice checks are skipped while the voice plugin is off; a healthy '
      'setup reports nothing', () async {
    final checkup = AssistantCheckup(
      settings: () async => settingsWith([
        deepSeek(keys: const ['sk-1']),
      ], 'deepseek:deepseek-flash'),
      roles: () async => [_role('ok')],
      presets: () async => const [],
      voiceEnabled: () => false,
      callUnavailable: (_) async => fail('voice checked while off'),
    );
    expect(await checkup.run(), isEmpty);
  });
}

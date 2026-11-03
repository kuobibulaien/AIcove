import 'dart:io';

import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_preset_store.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/tavern_compatibility_port.dart';
import 'package:flutter_test/flutter_test.dart';

const _flat = '''{"name":"组合A","prompts":[
{"identifier":"main","name":"主提示","content":"规则A","role":"system"},
{"identifier":"charDescription","marker":true},
{"identifier":"chatHistory","marker":true}],"prompt_order":[
{"identifier":"main","enabled":true},
{"identifier":"charDescription","enabled":true},
{"identifier":"chatHistory","enabled":true}]}''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SillyTavernPresetStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tavern_prompt_edit_');
    store = SillyTavernPresetStore(
      documentsDirectoryResolver: () async => directory,
    );
  });
  tearDown(() => directory.delete(recursive: true));

  SillyTavernPresetStore reopen() =>
      SillyTavernPresetStore(documentsDirectoryResolver: () async => directory);

  test('新增提示词排在聊天记录之前并默认开启，重开后仍在', () async {
    final preset = await store.importSource(_flat, sourceFileName: 'a.json');
    await store.savePrompt(
      preset.id,
      identifier: 'mine',
      name: '我的规则',
      role: 'user',
      content: '说话简短',
    );
    final updated = (await reopen().get(preset.id))!;
    expect(updated.selectedOrder.entries.map((e) => e.identifier), [
      'main',
      'charDescription',
      'mine',
      'chatHistory',
    ]);
    final mine = updated.enabledPrompts.singleWhere(
      (p) => p.identifier == 'mine',
    );
    expect(mine.name, '我的规则');
    expect(mine.role, 'user');
    expect(mine.content, '说话简短');
    expect(mine.marker, isFalse);
  });

  test('修改已有提示词只改名称、角色和正文，顺序与开关不变', () async {
    final preset = await store.importSource(_flat, sourceFileName: 'a.json');
    await store.setPromptEnabled(preset.id, 'main', false);
    await store.savePrompt(
      preset.id,
      identifier: 'main',
      name: '新名字',
      role: 'assistant',
      content: '规则B',
    );
    final updated = (await reopen().get(preset.id))!;
    expect(updated.prompts, hasLength(3));
    expect(updated.selectedOrder.entries, hasLength(3));
    expect(updated.selectedOrder.entries.first.enabled, isFalse);
    final main = updated.promptsById['main']!;
    expect(main.name, '新名字');
    expect(main.role, 'assistant');
    expect(main.content, '规则B');
  });

  test('占位条目和未知角色拒绝保存', () async {
    final preset = await store.importSource(_flat, sourceFileName: 'a.json');
    await expectLater(
      store.savePrompt(
        preset.id,
        identifier: 'chatHistory',
        name: 'x',
        role: 'system',
        content: 'x',
      ),
      throwsStateError,
    );
    await expectLater(
      store.savePrompt(
        preset.id,
        identifier: 'mine',
        name: 'x',
        role: 'tool',
        content: 'x',
      ),
      throwsStateError,
    );
    expect((await store.get(preset.id))!.prompts, hasLength(3));
  });

  test('分组顺序写进当前使用的那一组', () async {
    final preset = await store.importSource(
      '''{"prompts":[{"identifier":"main","content":"A"},
      {"identifier":"chatHistory","marker":true}],"prompt_order":[
      {"character_id":100000,"order":[{"identifier":"main"}]},
      {"character_id":100001,"order":[{"identifier":"main"},{"identifier":"chatHistory"}]}]}''',
      sourceFileName: 'g.json',
    );
    expect(preset.selectedOrder.sourceIndex, 1);
    await store.savePrompt(
      preset.id,
      identifier: 'mine',
      name: '我的',
      role: 'system',
      content: 'B',
    );
    final updated = (await reopen().get(preset.id))!;
    expect(updated.selectedOrder.entries.map((e) => e.identifier), [
      'main',
      'mine',
      'chatHistory',
    ]);
    expect(updated.promptOrderGroups.first.entries, hasLength(1));
  });

  test('Prompt Manager 导出的空正文占位可以补上正文', () async {
    final preset = await store.importSource(
      '''{"type":"prompt_manager","data":{"prompts":[],"prompt_order":[
      {"character_id":100001,"order":[{"identifier":"main"},{"identifier":"chatHistory"}]}]}}''',
      sourceFileName: 'pm.json',
    );
    await store.savePrompt(
      preset.id,
      identifier: 'main',
      name: '主提示',
      role: 'system',
      content: '补上的正文',
    );
    final updated = (await reopen().get(preset.id))!;
    expect(updated.promptsById['main']!.content, '补上的正文');
    expect(updated.selectedOrder.entries, hasLength(2));
  });

  test('空白预设也能添加提示词', () async {
    final preset = await store.importSource(
      kBasicContextPresetSource,
      sourceFileName: '基础上下文.json',
    );
    await store.savePrompt(
      preset.id,
      identifier: 'mine',
      name: '我的系统提示词',
      role: 'system',
      content: '你是一只猫',
    );
    final updated = (await reopen().get(preset.id))!;
    final ids = updated.selectedOrder.entries.map((e) => e.identifier).toList();
    expect(ids.indexOf('mine'), ids.indexOf('chatHistory') - 1);
  });

  test('删除自己加的提示词：条目、各组顺序和开关一起清掉', () async {
    final preset = await store.importSource(
      '''{"prompts":[{"identifier":"main","content":"A"},
      {"identifier":"chatHistory","marker":true}],"prompt_order":[
      {"character_id":100000,"order":[{"identifier":"main"}]},
      {"character_id":100001,"order":[{"identifier":"main"},{"identifier":"chatHistory"}]}]}''',
      sourceFileName: 'g.json',
    );
    const id = '${kUserPromptIdPrefix}1';
    await store.savePrompt(
      preset.id,
      identifier: id,
      name: '我的',
      role: 'system',
      content: 'B',
    );
    await store.setPromptEnabled(preset.id, id, false);
    await store.deletePrompt(preset.id, id);
    final updated = (await reopen().get(preset.id))!;
    expect(updated.promptsById.containsKey(id), isFalse);
    expect(updated.selectedOrder.entries.map((e) => e.identifier), [
      'main',
      'chatHistory',
    ]);
    expect(
      (updated.compatibilityData['promptEnabled'] as Map?)?.containsKey(id),
      isNot(isTrue),
    );
    expect(updated.warnings.where((w) => w.contains('未知节点')), isEmpty);
  });

  test('导入来的条目不能删除', () async {
    final preset = await store.importSource(_flat, sourceFileName: 'a.json');
    await expectLater(store.deletePrompt(preset.id, 'main'), throwsStateError);
    await expectLater(
      store.deletePrompt(preset.id, '${kUserPromptIdPrefix}missing'),
      throwsStateError,
    );
    expect((await store.get(preset.id))!.prompts, hasLength(3));
  });
}

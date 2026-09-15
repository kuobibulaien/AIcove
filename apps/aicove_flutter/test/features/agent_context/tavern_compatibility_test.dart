import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_preset_store.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_preset_assembler.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_preset_parser.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_regex_processor.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_world_book.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/tavern_compatibility_port.dart';

const presetSource = '''{"name":"组合A","prompts":[
{"identifier":"main","content":"规则A","role":"system"},
{"identifier":"worldInfoBefore","marker":true},
{"identifier":"charDescription","marker":true},
{"identifier":"worldInfoAfter","marker":true},
{"identifier":"chatHistory","marker":true}],"prompt_order":[
{"identifier":"main","enabled":true},
{"identifier":"worldInfoBefore","enabled":true},
{"identifier":"charDescription","enabled":true},
{"identifier":"worldInfoAfter","enabled":true},
{"identifier":"chatHistory","enabled":true}]}''';

Map<String, dynamic> worldSource(List<Map<String, dynamic>> entries) => {
  'name': '书',
  'entries': {for (var i = 0; i < entries.length; i++) '$i': entries[i]},
};

Future<TavernWorldScanResult> scanEntries(
  List<Map<String, dynamic>> entries, {
  List<Map<String, dynamic>>? messages,
  int budget = 2048,
  Map<String, String> macros = const {},
}) => const TavernWorldScanner().scan(
  books: [TavernWorldBook.parse(worldSource(entries), 'book.json')],
  messages:
      messages ??
      [
        {'role': 'user', 'content': '猫 森林'},
      ],
  tokenBudget: budget,
  macroValues: macros,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SillyTavernPresetStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tavern_core_');
    store = SillyTavernPresetStore(
      documentsDirectoryResolver: () async => directory,
    );
  });
  tearDown(() => directory.delete(recursive: true));

  test('扫描上限只计算实际扫描窗口，不被早期巨型消息阻断', () async {
    final scan = await scanEntries(
      [
        {
          'key': ['猫'],
          'scanDepth': 1,
          'content': '命中',
        },
      ],
      messages: [
        {'role': 'assistant', 'content': '旧' * (2 * 1024 * 1024 + 1)},
        {'role': 'user', 'content': '猫'},
      ],
    );
    expect(scan.injections.single.content, '命中');
  });
  test('空角色过滤器不是启用高级条件', () async {
    final scan = await scanEntries([
      {
        'constant': true,
        'content': '正常条目',
        'characterFilter': {'isExclude': false, 'names': [], 'tags': []},
      },
    ]);
    expect(scan.injections.single.content, '正常条目');
  });
  test('世界书不在聊天深度时忽略regex深度限制', () async {
    final preset = const SillyTavernPresetParser().parseMap(
      jsonDecode(presetSource),
      sourceFileName: 'p',
      compatibilityData: {
        'importedRegex': [
          {
            'id': 'r',
            'findRegex': '旧',
            'replaceString': '新',
            'placement': [5],
            'promptOnly': true,
            'minDepth': 0,
            'maxDepth': 0,
          },
        ],
      },
    );
    final scan = await scanEntries([
      {'constant': true, 'position': 0, 'content': '旧'},
    ]);
    final result = await const SillyTavernRegexProcessor().applyToWorldInfo(
      scan: scan,
      scripts: preset.regexScripts,
      authorized: true,
    );
    expect(result.injections.single.content, '新');
  });

  test('常驻、关键词、关闭、未命中都有独立结果', () async {
    final scan = await scanEntries([
      {'constant': true, 'content': '常驻'},
      {
        'key': ['猫'],
        'content': '命中',
      },
      {'constant': true, 'disable': true, 'content': '关闭'},
      {
        'key': ['狗'],
        'content': '未命中',
      },
    ]);
    expect(scan.injections.map((e) => e.content), containsAll(['常驻', '命中']));
    expect(scan.injections, hasLength(2));
    expect(scan.traces, hasLength(4));
  });

  for (final logic in [0, 1, 2, 3]) {
    test('次关键词逻辑 $logic 正确', () async {
      final scan = await scanEntries([
        {
          'key': ['猫'],
          'keysecondary': ['森林', '河'],
          'selectiveLogic': logic,
          'content': '条件内容',
        },
      ]);
      expect(scan.injections.length, [0, 1].contains(logic) ? 1 : 0);
    });
  }
  test('scanDepth 为0不扫描聊天；常驻仍可用', () async {
    final scan = await scanEntries([
      {
        'key': ['猫'],
        'scanDepth': 0,
        'content': '不触发',
      },
      {'constant': true, 'scanDepth': 0, 'content': '常驻'},
    ]);
    expect(scan.injections.single.content, '常驻');
  });
  test('逐条扫描深度、多模态文字、用户/角色宏', () async {
    final scan = await scanEntries(
      [
        {
          'key': ['旧词'],
          'scanDepth': 1,
          'content': '旧条目',
        },
        {
          'key': ['旧词'],
          'scanDepth': 2,
          'content': '{{char}}/{{user}}',
        },
      ],
      messages: [
        {'role': 'assistant', 'content': '旧词'},
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '新词'},
            {'type': 'image_url', 'image_url': '旧词'},
          ],
        },
      ],
      macros: {'char': '角色', 'user': '用户'},
    );
    expect(scan.injections.single.content, '角色/用户');
  });
  test('关键词支持大小写、整词和JS风格正则', () async {
    final scan = await scanEntries(
      [
        {
          'key': ['CAT'],
          'content': '默认不区分',
        },
        {
          'key': ['CAT'],
          'caseSensitive': true,
          'content': '不触发',
        },
        {
          'key': ['cat'],
          'matchWholeWords': true,
          'content': '不匹配catapult',
        },
        {
          'key': ['/CAT.+/i'],
          'content': '正则',
        },
      ],
      messages: [
        {'role': 'user', 'content': 'catapult'},
      ],
    );
    expect(scan.injections.map((e) => e.content), containsAll(['默认不区分', '正则']));
    expect(scan.injections, hasLength(2));
  });
  test('病态关键词正则超时终止而不是卡死主线程', () async {
    final scan = await scanEntries(
      [
        {
          'key': [r'/^(a+)+$/'],
          'content': '不能到达',
        },
      ],
      messages: [
        {'role': 'user', 'content': '${'a' * 30000}!'},
      ],
    );
    expect(scan.injections, isEmpty);
    expect(scan.warnings, contains(contains('1500ms')));
  });
  test('无效关键词只跳过该条目', () async {
    final scan = await scanEntries([
      {
        'key': ['/[bad/'],
        'content': '坏',
      },
      {'constant': true, 'content': '好'},
    ]);
    expect(scan.injections.single.content, '好');
    expect(scan.warnings, isNotEmpty);
  });
  test('概率0不激活、未知位置与高级条件不静默生效', () async {
    final scan = await scanEntries([
      {'constant': true, 'probability': 0, 'content': '概率0'},
      {'constant': true, 'position': 2, 'content': '作者注'},
      {'constant': true, 'sticky': 3, 'content': '粘性'},
      {'constant': true, 'group': 'group', 'content': '分组'},
    ]);
    expect(scan.injections, isEmpty);
    expect(scan.warnings.length, 3);
  });
  test('预算先按高order入选，最终按order升序插入', () async {
    final scan = await scanEntries([
      {'constant': true, 'order': 1, 'content': 'A'},
      {'constant': true, 'order': 200, 'content': 'B'},
      {'constant': true, 'order': 100, 'content': 'C'},
    ], budget: 10);
    expect(scan.injections.map((e) => e.content), ['C', 'B']);
    expect(scan.traces, contains(containsPair('reason', 'budget')));
  });
  test('支持角色卡character_book字段映射', () {
    final book = TavernWorldBook.parse({
      'data': {
        'character_book': {
          'entries': [
            {
              'id': 5,
              'keys': ['猫'],
              'secondary_keys': ['森林'],
              'enabled': false,
              'insertion_order': 42,
              'position': 'after_char',
              'content': '内容',
              'extensions': {'position': 4, 'depth': 3, 'role': 2},
            },
          ],
        },
      },
    }, 'character.json');
    final entry = book.entries.single;
    expect(entry.id, '5');
    expect(entry.enabled, isFalse);
    expect(entry.order, 42);
    expect(entry.position, 4);
    expect(entry.depth, 3);
    expect(entry.role, 'assistant');
  });
  test('拒绝重复条目ID和非世界书文件', () {
    expect(
      () => TavernWorldBook.parse(
        worldSource([
          {'uid': 1},
          {'uid': 1},
        ]),
        'x',
      ),
      throwsFormatException,
    );
    expect(
      () => TavernWorldBook.parse({'prompts': []}, 'x'),
      throwsFormatException,
    );
  });

  test('逐条开关重启持久化、并发保存不覆盖、原始预设不改写', () async {
    final preset = await store.importSource(
      presetSource,
      sourceFileName: 'a.json',
    );
    await store.importRegex(
      preset.id,
      '{"id":"r","findRegex":"猫","replaceString":"狗","placement":[1],"promptOnly":true}',
    );
    await store.importWorldBook(
      preset.id,
      jsonEncode(
        worldSource([
          {'uid': 0, 'constant': true, 'content': '世界'},
        ]),
      ),
      '书.json',
    );
    final bookId = (await store.get(preset.id))!.worldBooks.single.id;
    await Future.wait([
      store.setPromptEnabled(preset.id, 'main', false),
      store.setRegexEnabled(preset.id, 'r', false),
      store.setWorldEntryEnabled(preset.id, bookId, '0', false),
      store.setRegexAuthorization(preset.id, true),
    ]);
    final reopened = SillyTavernPresetStore(
      documentsDirectoryResolver: () async => directory,
    );
    final updated = (await reopened.get(preset.id))!;
    expect(updated.enabledPrompts.any((p) => p.identifier == 'main'), isFalse);
    expect(updated.regexScripts.single.disabled, isTrue);
    expect(updated.worldBooks.single.entries.single.enabled, isFalse);
    expect(updated.regexAuthorized, isTrue);
    expect(updated.rawPreset, preset.rawPreset);
    await reopened.importSource(
      presetSource,
      sourceFileName: 'a.json',
      regexAuthorized: true,
    );
    expect((await reopened.get(preset.id))!.worldBooks, hasLength(1));
  });
  test('存储信封ID错配不得把A的条目开关写进B', () async {
    final a = await store.importSource(presetSource, sourceFileName: 'a');
    final b = await store.importSource(
      presetSource.replaceAll('组合A', '组合B'),
      sourceFileName: 'b',
    );
    final file = File(
      '${directory.path}/aicove/sillytavern_presets/${a.id}.json',
    );
    final envelope =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    envelope['id'] = b.id;
    await file.writeAsString(jsonEncode(envelope));
    await expectLater(
      store.setPromptEnabled(a.id, 'main', false),
      throwsStateError,
    );
    expect((await store.get(b.id))!.name, '组合B');
    expect(
      (await store.get(
        b.id,
      ))!.enabledPrompts.any((p) => p.identifier == 'main'),
      isTrue,
    );
  });

  test('默认引用失效时拒绝保存；旧存储的 enabled=false 读取归一为启用', () async {
    // 失效引用无论 enabled 取值都不得写入，否则读取归一后会在请求时抛错
    await expectLater(
      store.savePluginSettings(
        const TavernPluginSettings(
          enabled: false,
          defaultPresetId: 'st_preset_aaaaaaaaaaaaaaaaaaaaaaaa',
        ),
      ),
      throwsStateError,
    );
    await expectLater(
      store.savePluginSettings(
        const TavernPluginSettings(
          defaultPresetId: 'st_preset_aaaaaaaaaaaaaaaaaaaaaaaa',
        ),
      ),
      throwsStateError,
    );
    // 旧版本可能已存过 enabled=false；读取时归一为常开
    await store.savePluginSettings(const TavernPluginSettings(enabled: false));
    expect((await store.loadPluginSettings()).enabled, isTrue);
  });

  test('默认、角色显式绑定与失效引用', () async {
    final a = await store.importSource(presetSource, sourceFileName: 'a.json');
    final b = await store.importSource(
      presetSource.replaceAll('组合A', '组合B'),
      sourceFileName: 'b.json',
    );
    await store.savePluginSettings(TavernPluginSettings(defaultPresetId: a.id));
    expect((await store.resolvePreset(null))!.id, a.id);
    final snapshot = (await store.resolvePreset(b.id))!;
    await store.setPromptEnabled(b.id, 'main', false);
    expect(snapshot.enabledPrompts.any((p) => p.identifier == 'main'), isTrue);
    expect(
      (await store.resolvePreset(
        b.id,
      ))!.enabledPrompts.any((p) => p.identifier == 'main'),
      isFalse,
    );
    await expectLater(
      store.resolvePreset('st_preset_aaaaaaaaaaaaaaaaaaaaaaaa'),
      throwsStateError,
    );
    // 全局开关已移除：enabled=false 写入后读取归一为启用，默认预设照常生效
    await store.savePluginSettings(
      TavernPluginSettings(enabled: false, defaultPresetId: a.id),
    );
    expect((await store.resolvePreset(b.id))!.id, b.id);
    expect((await store.resolvePreset(null))!.id, a.id);
  });
  test('整本与条目开关可分别恢复；重复导入不覆盖开关', () async {
    final p = await store.importSource(presetSource, sourceFileName: 'a');
    final source = jsonEncode(
      worldSource([
        {'constant': true, 'content': '世界'},
      ]),
    );
    await store.importWorldBook(p.id, source, 'w');
    final id = (await store.get(p.id))!.worldBooks.single.id;
    await store.setWorldBookEnabled(p.id, id, false);
    await store.importWorldBook(p.id, source, 'w');
    var book = (await store.get(p.id))!.worldBooks.single;
    expect(book.enabled, isFalse);
    expect(
      (await const TavernWorldScanner().scan(
        books: [book],
        messages: [],
        tokenBudget: 100,
      )).injections,
      isEmpty,
    );
    await store.setWorldBookEnabled(p.id, id, true);
    book = (await store.get(p.id))!.worldBooks.single;
    expect(
      (await const TavernWorldScanner().scan(
        books: [book],
        messages: [],
        tokenBudget: 100,
      )).injections,
      hasLength(1),
    );
  });
  test('独立regex与内嵌regex统一授权/逐条处理，不改输入', () async {
    final p = await store.importSource(presetSource, sourceFileName: 'p');
    await store.importRegex(
      p.id,
      '[{"id":"r","findRegex":"猫","replaceString":"狗","placement":[1],"promptOnly":true}]',
    );
    final preset = (await store.get(p.id))!;
    final messages = [
      {'role': 'user', 'content': '猫'},
    ];
    const processor = SillyTavernRegexProcessor();
    var result = await processor.applyToPromptMessages(
      messages: messages,
      scripts: preset.regexScripts,
      authorized: false,
    );
    expect(result.messages.single['content'], '猫');
    result = await processor.applyToPromptMessages(
      messages: messages,
      scripts: preset.regexScripts,
      authorized: true,
    );
    expect(result.messages.single['content'], '狗');
    expect(messages.single['content'], '猫');
  });
  test('世界书命中+placement5正则+prompt marker与深度是实际最终上下文', () async {
    final preset = const SillyTavernPresetParser().parseSource(
      presetSource,
      sourceFileName: 'p',
    );
    final parsedRegex = const SillyTavernPresetParser().parseMap(
      preset.rawPreset,
      sourceFileName: 'p',
      compatibilityData: {
        'importedRegex': [
          {
            'id': 'wi',
            'findRegex': '旧词',
            'replaceString': '新词',
            'placement': [5],
            'promptOnly': true,
          },
        ],
      },
    );
    final scan = await scanEntries([
      {'constant': true, 'position': 0, 'content': '之前旧词'},
      {'constant': true, 'position': 1, 'content': '之后'},
      {'constant': true, 'position': 4, 'depth': 1, 'role': 2, 'content': '深度'},
    ]);
    final transformed = await const SillyTavernRegexProcessor()
        .applyToWorldInfo(
          scan: scan,
          scripts: parsedRegex.regexScripts,
          authorized: true,
        );
    final assembled = const SillyTavernPresetAssembler().assemble(
      preset: preset,
      historyMessages: [
        {'role': 'user', 'content': '问题'},
      ],
      context: SillyTavernAssemblyContext(
        characterName: '角色',
        userName: '我',
        characterDescription: '角色定义',
        scenario: '',
        worldInjections: transformed.injections,
      ),
      maxContextTokens: 8000,
    );
    expect(assembled.messages.map((m) => m['content']), [
      '规则A',
      '之前新词',
      '角色定义',
      '之后',
      '深度',
      '问题',
    ]);
    expect(assembled.messages[4]['role'], 'assistant');
    expect(scan.injections.first.content, contains('旧词'));
  });
}

// ADR0094: AIcove酱's quick panels list live data, run taps through the
// assistant's tools, keep what the user picked and did, and render only
// where the assistant chat provides them.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show ToolEffect;
import 'package:aicove_flutter/src/features/assistant/application/assistant_cards.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_panel_actions.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_review.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_role_tools.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_settings_tools.dart';
import 'package:aicove_flutter/src/features/assistant/assistant_panel_providers.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset_provider.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/ui_blocks/application/ui_block_state_store.dart';
import 'package:aicove_flutter/src/features/ui_blocks/domain/ui_saved_state.dart';
import 'package:aicove_flutter/src/ui/features/assistant/widgets/assistant_quick_panels.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/ui_blocks/moe_ui_block.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/ui_blocks/moe_ui_block_scope.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../features/assistant/assistant_onboarding_test.dart'
    show FakeSettings, deepSeek, settingsWith;

const _writePreview = bool.fromEnvironment('WRITE_UI_BLOCK_PREVIEW');
const _conversation = 'aicove_assistant';

Conversation _role(String id, String name, {String? drawing, String? voice}) =>
    Conversation(
      id: id,
      title: name,
      displayName: name,
      description: '$name的简介',
      personaPrompt: PersonaPromptCodec.compose(
        userPrompt: '我是$name',
        drawingPresetId: drawing,
      ),
      voiceFile: voice,
      createdAt: DateTime(2026, 10, 19),
      updatedAt: DateTime(2026, 10, 19),
    );

class _Roles extends ConversationsNotifier {
  @override
  Future<List<Conversation>> build() async => [
    _role('nahida', '纳西妲', drawing: 'drawing_default', voice: 'voice_b'),
    _role('xiaoxue', '小雪', drawing: 'drawing_b'),
    _role('kaiya', '凯亚'),
  ];
}

class _Catalog extends DrawingPresetCatalogNotifier {
  @override
  Future<DrawingPresetCatalog> build() async => DrawingPresetCatalog(
    presets: const [
      DrawingPreset(
        id: 'drawing_default',
        name: '默认绘图',
        config: ImageConfig(selectedModelId: 'novelai:nai-diffusion-4-5'),
      ),
      DrawingPreset(
        id: 'drawing_b',
        name: '水彩',
        config: ImageConfig(selectedModelId: 'openai:gpt-image-1'),
      ),
    ],
    defaultPresetId: 'drawing_default',
    legacyConfig: const ImageConfig(),
  );
}

class _Tts extends TtsPluginConfigNotifier {
  void use(TtsConfig config) => state = config;
}

final _voices = TtsConfig(
  voicePresets: [
    VoicePreset.defaultPreset,
    VoicePreset.defaultPreset.copyWith(id: 'voice_b', name: '纳西妲的声音'),
  ],
  defaultVoicePresetId: VoicePreset.defaultPreset.id,
);

/// When set, tool calls wait for it: a write still in flight.
Completer<void>? _gate;

/// Calls the panels made, as (tool, args).
final _calls = <(String, Map<String, dynamic>)>[];

AITool _recording(String name) => AITool(
  name: name,
  description: '',
  parameters: const {},
  effect: ToolEffect.write,
  handler: (args) async {
    _calls.add((name, args));
    await _gate?.future;
    return jsonEncode({'ok': true, 'change': '改好了', 'undo': '可撤销'});
  },
);

final _actions = AssistantPanelActions(
  tools: () => [
    _recording(AssistantRoleTools.setDrawingPreset),
    _recording(AssistantRoleTools.setVoice),
    _recording(AssistantSettingsTools.setTool),
    _recording(AssistantCardTools.requestKey),
  ],
  riskOf: (name, _) => AssistantRisk.reversible,
  describe: (name, _) => ApprovalPrompt(title: name, detail: ''),
  alwaysAsk: () => false,
);

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [
      appSettingsProvider.overrideWith(
        () => FakeSettings(
          settingsWith([
            deepSeek(keys: const ['sk-1']),
            deepSeek().copyWith(id: 'openai', displayName: 'OpenAI'),
          ], 'deepseek:deepseek-flash'),
        ),
      ),
      conversationsProvider.overrideWith(_Roles.new),
      drawingPresetCatalogProvider.overrideWith(_Catalog.new),
      ttsPluginConfigProvider.overrideWith((ref) => _Tts()),
      assistantPanelActionsProvider.overrideWithValue(_actions),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Widget _host(
  ProviderContainer container,
  Widget child, {
  bool actions = true,
  ValueChanged<String>? onAsk,
  GlobalKey? capture,
  double width = 400,
  bool dark = false,
}) => UncontrolledProviderScope(
  container: container,
  child: SkinScope(
    skin: const MoeTalkSkin(),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: dark ? Brightness.dark : Brightness.light,
        fontFamily: _writePreview ? 'Preview' : null,
        extensions: [dark ? MoeColors.dark() : MoeColors.light()],
      ),
      home: Builder(
        builder: (context) => Scaffold(
          backgroundColor: context.moeColors.bgMain,
          body: SingleChildScrollView(
            child: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                key: capture,
                child: ColoredBox(
                  color: context.moeColors.bgMain,
                  child: SizedBox(
                    width: width,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: MoeUiBlockScope(
                        conversationId: _conversation,
                        onAsk: onAsk ?? (_) {},
                        actions: actions ? kAssistantQuickPanels : null,
                        child: MoeUiBlockMessage(messageId: 'm1', child: child),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

Widget _panel(String json) => MoeUiBlock(code: json, closed: true);

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget host,
) async {
  await tester.pumpWidget(host);
  await tester.pumpAndSettle();
  (container.read(ttsPluginConfigProvider.notifier) as _Tts).use(_voices);
  await tester.pumpAndSettle();
}

/// Lets the toast and the state store's save timer run out.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 10));
  await tester.pumpAndSettle();
}

const _drawing =
    '{"component": "drawing-presets", "id": "nahida-drawing", "title": "纳西妲的绘图预设", "role": "nahida"}';
const _roles =
    '{"component": "roles", "id": "pick-role", "purpose": "drawing"}';
const _voicesPanel =
    '{"component": "voice-presets", "id": "nahida-voice", "role": "nahida"}';
const _settings =
    '{"component": "settings", "id": "look", "title": "外观", "keys": ["appearance.theme", "chat.message_chunking", "appearance.text_scale", "model.default_chat", "nope.key"]}';
const _providers = '{"component": "providers", "id": "channels"}';

void main() {
  setUpAll(() async {
    if (!_writePreview) return;
    for (final entry in {
      'Preview': '/System/Library/Fonts/STHeiti Medium.ttc',
      'MaterialIcons':
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final loader = FontLoader(entry.key);
      loader.addFont(
        File(entry.value).readAsBytes().then(ByteData.sublistView),
      );
      await loader.load();
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _calls.clear();
    _gate = null;
  });

  testWidgets('a write finishing after another pick keeps the new pick whole', (
    tester,
  ) async {
    final container = _container();
    await _pump(tester, container, _host(container, _panel(_drawing)));
    _gate = Completer<void>();
    await tester.tap(find.text('水彩').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('给纳西妲用'));
    await tester.pump();
    await tester.tap(find.text('跟随默认'));
    await tester.pump();
    _gate!.complete();
    await tester.pumpAndSettle();
    final saved = container
        .read(uiBlockStateProvider(_conversation))['m1/nahida-drawing']!
        .state;
    expect(saved['picked'], '-default');
    expect(saved['pickedName'], '跟随默认');
    expect(saved['did'], ['把「纳西妲」的绘图预设换成了「水彩」']);
    await _settle(tester);
  });

  test('a picked id is kept whole or dropped, never cut', () {
    final long = 'legacy_${'a' * 100}';
    expect(
      uiCleanActionState({'picked': long, 'pickedName': '旧预设'})['picked'],
      long,
    );
    expect(uiCleanActionState({'picked': 'x' * 300}), isEmpty);
    expect(
      (uiCleanActionState({
                'did': [for (var i = 0; i < 9; i++) '$i'],
              })['did']
              as List)
          .length,
      5,
    );
  });

  test('a storage failure ends as a message', () async {
    final actions = AssistantPanelActions(
      tools: () => [
        AITool(
          name: 'aicove_x',
          description: '',
          parameters: const {},
          effect: ToolEffect.write,
          handler: (_) async => throw const FileSystemException('disk full'),
        ),
      ],
      riskOf: (_, _) => AssistantRisk.reversible,
      describe: (name, _) => ApprovalPrompt(title: name, detail: ''),
      alwaysAsk: () => false,
    );
    expect(
      await actions.run('aicove_x', const {}, confirm: (_) async => true),
      isA<PanelActionFailed>(),
    );
  });

  testWidgets(
    'drawing presets: marks the role\'s preset and swaps it through the tool',
    (tester) async {
      final container = _container();
      await _pump(tester, container, _host(container, _panel(_drawing)));

      expect(find.text('纳西妲的绘图预设'), findsOneWidget);
      expect(find.text('纳西妲在用'), findsOneWidget);
      expect(find.text('水彩'), findsOneWidget);

      await tester.tap(find.text('水彩'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('给纳西妲用'));
      await tester.pumpAndSettle();

      expect(_calls.single.$1, AssistantRoleTools.setDrawingPreset);
      expect(_calls.single.$2, {'role_id': 'nahida', 'preset_id': 'drawing_b'});
      final saved = container
          .read(uiBlockStateProvider(_conversation))['m1/nahida-drawing']!
          .state;
      expect(saved['picked'], 'drawing_b');
      expect(saved['did'], ['把「纳西妲」的绘图预设换成了「水彩」']);
      await _settle(tester);
    },
  );

  testWidgets('roles: picking one hands a half sentence to the composer', (
    tester,
  ) async {
    final container = _container();
    final asked = <String>[];
    await _pump(
      tester,
      container,
      _host(container, _panel(_roles), onAsk: asked.add),
    );

    expect(find.text('跟随默认：默认绘图'), findsOneWidget);
    await tester.tap(find.text('纳西妲'));
    await tester.pumpAndSettle();
    expect(find.text('打开绘图预设'), findsOneWidget);
    await tester.tap(find.text('交给 AIcove酱'));
    expect(asked, ['帮我改一下「纳西妲」的绘图预设：']);
    expect(_calls, isEmpty);
  });

  testWidgets('voice presets: the role can be unbound from its voice', (
    tester,
  ) async {
    final container = _container();
    await _pump(tester, container, _host(container, _panel(_voicesPanel)));

    expect(find.text('纳西妲在用'), findsOneWidget);
    await tester.tap(find.text('不单独绑定'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('给纳西妲用'));
    await tester.pumpAndSettle();
    expect(_calls.single.$2, {'role_id': 'nahida', 'voice_id': ''});
    await _settle(tester);
  });

  testWidgets(
    'settings: controls follow the whitelist and write through the tool',
    (tester) async {
      final container = _container();
      await _pump(tester, container, _host(container, _panel(_settings)));

      expect(find.text('深浅色'), findsOneWidget);
      expect(find.text('启用消息分段'), findsOneWidget);
      expect(find.textContaining('认不出的设置项：nope.key'), findsOneWidget);
      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();
      expect(_calls.single.$2, {'key': 'appearance.theme', 'value': 'dark'});
      await _settle(tester);
    },
  );

  testWidgets('providers: a channel without a key offers the key card', (
    tester,
  ) async {
    final container = _container();
    await _pump(tester, container, _host(container, _panel(_providers)));

    expect(find.text('没有 Key'), findsOneWidget);
    await tester.tap(find.text('OpenAI'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('填 Key'));
    await tester.pumpAndSettle();
    expect(_calls.single.$1, AssistantCardTools.requestKey);
    expect(_calls.single.$2, {'provider_id': 'openai'});
    await _settle(tester);
  });

  testWidgets('outside the assistant chat a panel only shows a note', (
    tester,
  ) async {
    final container = _container();
    await _pump(
      tester,
      container,
      _host(container, _panel(_drawing), actions: false),
    );

    expect(find.textContaining('只在 AIcove酱的聊天里能用'), findsOneWidget);
    expect(find.text('水彩'), findsNothing);
  });

  test('a major tap waits for the user and a refusal runs nothing', () async {
    final actions = AssistantPanelActions(
      tools: () => [_recording(AssistantSettingsTools.setTool)],
      riskOf: (_, _) => AssistantRisk.major,
      describe: (name, _) => const ApprovalPrompt(title: '换模型', detail: ''),
      alwaysAsk: () => false,
    );
    final asked = <String>[];
    final refused = await actions.run(
      AssistantSettingsTools.setTool,
      {'key': 'model.default_chat'},
      confirm: (prompt) async {
        asked.add(prompt.title);
        return false;
      },
    );
    expect(refused, isA<PanelActionCancelled>());
    expect(asked, ['换模型']);
    expect(_calls, isEmpty);
    final unknown = await actions.run(
      'aicove_delete_everything',
      const {},
      confirm: (_) async => true,
    );
    expect(unknown, isA<PanelActionFailed>());
  });

  test('always-ask makes even a reversible tap wait; reads never do', () async {
    var risk = AssistantRisk.reversible;
    final actions = AssistantPanelActions(
      tools: () => [_recording(AssistantCardTools.requestKey)],
      riskOf: (_, _) => risk,
      describe: (name, _) => ApprovalPrompt(title: name, detail: ''),
      alwaysAsk: () => true,
    );
    var asked = 0;
    Future<bool> confirm(ApprovalPrompt _) async {
      asked++;
      return true;
    }

    expect(
      await actions.run(
        AssistantCardTools.requestKey,
        const {},
        confirm: confirm,
      ),
      isA<PanelActionDone>(),
    );
    expect(asked, 1);
    risk = AssistantRisk.readOnly;
    await actions.run(
      AssistantCardTools.requestKey,
      const {},
      confirm: confirm,
    );
    expect(asked, 1);
  });

  // 源码渲染预览：--dart-define=WRITE_UI_BLOCK_PREVIEW=true 时写到 scratch/quick-panels-20261019/。
  for (final (name, width, dark) in [
    ('narrow-light', 400.0, false),
    ('narrow-dark', 400.0, true),
    ('wide-light', 1100.0, false),
  ]) {
    testWidgets('preview $name', (tester) async {
      if (!_writePreview) return;
      tester.view.physicalSize = Size(width + 40, 3600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = _container();
      final capture = GlobalKey();
      await _pump(
        tester,
        container,
        _host(
          container,
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final json in [
                _drawing,
                _roles,
                _voicesPanel,
                _settings,
                _providers,
              ])
                _panel(json),
            ],
          ),
          capture: capture,
          width: width,
          dark: dark,
        ),
      );
      await tester.tap(find.text('水彩').first);
      await tester.tap(find.text('纳西妲').first);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final boundary =
            capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('../../scratch/quick-panels-20261019/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
      });
    });
  }
}

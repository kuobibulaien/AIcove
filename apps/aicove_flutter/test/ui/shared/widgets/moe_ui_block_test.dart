import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/ui_blocks/application/ui_block_state_store.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_code_block.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/ui_blocks/moe_ui_block.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/ui_blocks/moe_ui_block_scope.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/ui_blocks/ui_block_options.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _writePreview = bool.fromEnvironment('WRITE_UI_BLOCK_PREVIEW');

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings(
        ttsEnabled: false,
        defaultModelName: 'm',
        defaultPersonaPrompt: '',
        modelList: ['m'],
        allKnownModels: ['m'],
        modelDisplayNames: {},
        modelTypes: {},
        modelConfigs: {},
        apiKey: '',
        apiBaseUrl: '',
        imageGenerationEnabled: false,
        maxFileUploadMB: 10,
        contextWindowTokens: 1000,
        customModels: [],
        providers: [],
        modelProviderMap: {},
        backendApiKey: '',
        messageChunkingEnabled: false,
        messageFormatConfig: MessageFormatConfig(),
        textScaleFactor: 1.0,
        uiScaleFactor: 1.0,
        imagePreviewScale: 1.0,
        autoReplySettings: AutoReplySettings(),
        globalBackgroundColor: GlobalBackgroundColor.white,
        chatBackgroundColor: ChatBackgroundColor.defaultColor,
        isDarkMode: false,
        useSystemTheme: true,
        accentColor: 'FC96AA',
        hideUserAvatar: false,
      );
}

const _conversation = 'conv-1';

Widget _host(
  Widget child, {
  bool dark = false,
  ProviderContainer? container,
  ValueChanged<String>? onAsk,
  GlobalKey? capture,
  double width = 400,
}) {
  final app = SkinScope(
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
                        child: child,
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
  return container == null
      ? ProviderScope(
          overrides: [appSettingsProvider.overrideWith(_FakeAppSettingsNotifier.new)],
          child: app,
        )
      : UncontrolledProviderScope(container: container, child: app);
}

Widget _block(String code, {bool closed = true, String messageId = 'm1'}) =>
    MoeUiBlockMessage(
      messageId: messageId,
      child: MoeUiBlock(code: code, closed: closed),
    );

const _panel = '''
{"component": "panel", "id": "ctx-budget", "title": "上下文估算",
 "state": {"turns": 40, "perTurn": 300, "window": 64},
 "computed": {"used": "turns * perTurn * 2 / 1000", "ratio": "min(used / window, 1)"},
 "children": [
   {"component": "slider", "bind": "turns", "label": "保留轮数", "min": 10, "max": 200, "step": 10},
   {"component": "segmented", "bind": "window", "label": "上下文窗口（K）", "options": [32, 64, 128]},
   {"component": "stat", "label": "聊天记录约占", "value": "{round(used, 1)}", "unit": "K token"},
   {"component": "progress", "value": "{ratio}", "max": 1, "label": "占窗口 {round(ratio * 100)}%"},
   {"component": "callout", "tone": "warning", "text": "超过窗口，旧消息会被压缩", "visible": "{used > window}"},
   {"component": "button", "ask": "按保留 {turns} 轮、窗口 {window}K，帮我调一下上下文设置"}]}''';

const _checklist = '''
{"component": "checklist", "id": "voice-setup", "title": "语音通话准备",
 "items": [{"text": "选音色预设", "note": "决定角色用什么声音说话"}, "填语音渠道的 Key", "选识别来源"]}''';

const _tree = '''
{"component": "decision-tree", "id": "no-image", "title": "角色为什么不画画",
 "nodes": [
   {"id": "plugin", "text": "角色的插件里开了「绘图」吗？", "options": [{"label": "开了", "next": "preset"}, {"label": "没开", "next": "fix-plugin"}]},
   {"id": "preset", "text": "绑定的预设关了函数调用吗？", "options": [{"label": "关了", "next": "fix-preset"}, {"label": "没关", "next": "ask"}]},
   {"id": "fix-plugin", "text": "到角色编辑页打开「绘图」插件就行"},
   {"id": "fix-preset", "text": "预设关了函数调用时，绘图只能走内联标签"},
   {"id": "ask", "text": "把角色完整上下文页的截图发给我"}]}''';

const _steps = '''
{"component": "steps", "id": "get-key", "title": "拿 DeepSeek Key",
 "items": [{"title": "打开 DeepSeek 开放平台", "text": "用手机号注册登录"}, {"title": "充值", "text": "最低 10 元"}, {"title": "API Keys → 创建", "text": "Key 只显示一次，马上复制"}]}''';

const _quiz = '''
{"component": "quiz", "id": "ctx-quiz", "questions": [
  {"question": "上下文窗口满了会怎样？", "options": ["直接报错", "旧消息被压缩成摘要", "模型变聪明"], "answer": 1, "explanation": "AIcove 会把旧消息整理成摘要，原文仍留在本机。"}]}''';

const _stats = '''
{"component": "stat-grid", "title": "小雪的上下文", "items": [
  {"label": "系统提示词", "value": "3,120", "unit": "token"},
  {"label": "聊天记录", "value": "18,400", "unit": "token", "delta": "-2,100", "trend": "down", "tone": "positive"},
  {"label": "占窗口", "value": "33%"}]}''';

void main() {
  setUpAll(() async {
    if (!_writePreview) return;
    for (final entry in {
      'Preview': '/System/Library/Fonts/STHeiti Medium.ttc',
      'MaterialIcons':
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final loader = FontLoader(entry.key);
      loader.addFont(File(entry.value).readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [appSettingsProvider.overrideWith(_FakeAppSettingsNotifier.new)],
    );
    addTearDown(c.dispose);
    return c;
  }

  testWidgets('panel recomputes on input, stores the diff and asks', (tester) async {
    final c = container();
    final asked = <String>[];
    await tester.pumpWidget(_host(_block(_panel), container: c, onAsk: asked.add));
    await tester.pumpAndSettle();

    expect(find.text('上下文估算'), findsOneWidget);
    expect(find.textContaining('24 K token', findRichText: true), findsOneWidget); // 40 * 300 * 2 / 1000
    expect(find.text('超过窗口，旧消息会被压缩'), findsNothing);

    await tester.tap(find.text('32'));
    await tester.pumpAndSettle();
    expect(find.text('占窗口 75%'), findsOneWidget);
    expect(c.read(uiBlockStateProvider(_conversation))['m1/ctx-budget']!.state, {'window': 32});

    await tester.tap(find.textContaining('按保留 40 轮、窗口 32K'));
    expect(asked, ['按保留 40 轮、窗口 32K，帮我调一下上下文设置']);
  });

  testWidgets('restores stored values', (tester) async {
    final c = container();
    c.read(uiBlockStateProvider(_conversation).notifier).write('m1/ctx-budget', {'turns': 200, 'window': 32});
    await tester.pumpWidget(_host(_block(_panel), container: c));
    await tester.pumpAndSettle();
    expect(find.textContaining('120 K token', findRichText: true), findsOneWidget);
    expect(find.text('超过窗口，旧消息会被压缩'), findsOneWidget);
    // Let the store's delayed save run before the test ends.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('checklist stores what was ticked', (tester) async {
    final c = container();
    await tester.pumpWidget(_host(_block(_checklist), container: c));
    await tester.pumpAndSettle();
    expect(find.text('已完成 0 / 3'), findsOneWidget);
    await tester.tap(find.text('填语音渠道的 Key'));
    await tester.pumpAndSettle();
    expect(find.text('已完成 1 / 3'), findsOneWidget);
    expect(c.read(uiBlockStateProvider(_conversation))['m1/voice-setup']!.state, {'done': [1]});
    await tester.tap(find.text('填语音渠道的 Key'));
    await tester.pumpAndSettle();
    expect(c.read(uiBlockStateProvider(_conversation)).containsKey('m1/voice-setup'), isFalse);
  });

  testWidgets('decision tree walks to a conclusion and back', (tester) async {
    await tester.pumpWidget(_host(_block(_tree)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开了'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关了'));
    await tester.pumpAndSettle();
    expect(find.text('结论'), findsOneWidget);
    expect(find.text('预设关了函数调用时，绘图只能走内联标签'), findsOneWidget);
    await tester.tap(find.text('重来'));
    await tester.pumpAndSettle();
    expect(find.text('角色的插件里开了「绘图」吗？'), findsOneWidget);
  });

  testWidgets('quiz marks the answer', (tester) async {
    await tester.pumpWidget(_host(_block(_quiz)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('直接报错'));
    await tester.pumpAndSettle();
    expect(find.text('答对 0 / 1'), findsOneWidget);
    expect(find.textContaining('原文仍留在本机'), findsOneWidget);
  });

  testWidgets('form checks required fields, fills the composer, refuses secrets', (tester) async {
    final c = container();
    final asked = <String>[];
    await tester.pumpWidget(_host(_block('''
{"component": "form", "id": "new-role", "title": "新角色", "submit": "就按这些写",
 "fields": [{"key": "name", "label": "名字", "required": true},
            {"key": "traits", "label": "性格", "type": "multiselect", "options": ["温柔", "元气"]},
            {"key": "apiKey", "label": "API Key"}]}'''), container: c, onAsk: asked.add));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.textContaining('是机密信息'), findsOneWidget);

    await tester.tap(find.text('就按这些写'));
    await tester.pump();
    expect(find.text('这一项要填'), findsOneWidget);
    expect(asked, isEmpty);

    await tester.enterText(find.byType(TextField), '小雪');
    await tester.tap(find.text('温柔'));
    await tester.tap(find.text('元气'));
    await tester.pump();
    await tester.tap(find.text('就按这些写'));
    await tester.pump();
    expect(asked, ['【新角色】\n名字：小雪\n性格：温柔、元气']);
    expect(find.text('已填进输入框，确认后发送'), findsOneWidget);
    expect(c.read(uiBlockStateProvider(_conversation))['m1/new-role']!.state, {
      'values': {'name': '小雪', 'traits': ['温柔', '元气']},
    });
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('decision tree offers 其他 that fills the composer with the path so far', (tester) async {
    final asked = <String>[];
    await tester.pumpWidget(_host(_block(_tree), onAsk: asked.add));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开了'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('其他'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '我没绑定预设');
    await tester.pump();
    await tester.tap(find.text('填进输入框'));
    await tester.pump();
    expect(asked, ['【角色为什么不画画】\n角色的插件里开了「绘图」吗？ → 开了\n绑定的预设关了函数调用吗？ → 其他：我没绑定预设']);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('no 其他 when the block turns it off', (tester) async {
    await tester.pumpWidget(_host(_block(_tree.replaceFirst('"title"', '"other": false, "title"'))));
    await tester.pumpAndSettle();
    expect(find.text('其他'), findsNothing);
  });

  testWidgets('form select takes the user\'s own words through 其他', (tester) async {
    final c = container();
    final asked = <String>[];
    await tester.pumpWidget(_host(_block('''
{"component": "form", "id": "who", "fields": [
  {"key": "gender", "label": "性别", "type": "select", "options": ["女", "男"], "required": true},
  {"key": "traits", "label": "性格", "type": "multiselect", "options": ["温柔", "元气"]}]}'''), container: c, onAsk: asked.add));
    await tester.pumpAndSettle();
    expect(find.text('其他'), findsNWidgets(2));
    await tester.tap(find.text('女'));
    await tester.tap(find.text('其他').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('填好了'));
    await tester.pump();
    expect(find.text('这一项要填'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '无性别的机器人');
    await tester.tap(find.text('温柔'));
    await tester.tap(find.text('其他').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '有点社恐');
    await tester.pump();
    await tester.tap(find.text('填好了'));
    await tester.pump();
    expect(asked, ['性别：无性别的机器人\n性格：温柔、有点社恐']);
    expect(c.read(uiBlockStateProvider(_conversation))['m1/who']!.state, {
      'values': {'traits': ['温柔']},
      'other': {'gender': '无性别的机器人', 'traits': '有点社恐'},
    });
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('secret fields: required ones do not block, panel inputs are covered too', (tester) async {
    final asked = <String>[];
    await tester.pumpWidget(_host(_block('''
{"component": "form", "id": "f", "fields": [
  {"key": "name", "label": "名字"},
  {"key": "auth", "label": "认证信息", "placeholder": "粘贴 API Key", "required": true},
  {"key": "pass", "label": "暗号", "type": "password"},
  {"key": "tokens", "label": "token 档位", "type": "select", "options": ["低", "高"]}]}'''), onAsk: asked.add));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.textContaining('是机密信息'), findsNWidgets(2));
    expect(find.text('低'), findsOneWidget); // a choice is never a secret
    await tester.enterText(find.byType(TextField), '小雪');
    await tester.tap(find.text('填好了'));
    await tester.pump();
    expect(asked, ['名字：小雪']);

    await tester.pumpWidget(_host(_block('''
{"component": "panel", "state": {"k": ""}, "children": [{"component": "input", "bind": "k", "label": "DeepSeek API Key"}]}''')));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('不要填在这里'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('form picks up saved answers that load late, keeping what the user typed', (tester) async {
    final c = container();
    await tester.pumpWidget(_host(_block('''
{"component": "form", "id": "late", "fields": [{"key": "a", "label": "甲"}, {"key": "b", "label": "乙"}]}'''), container: c));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '我改的');
    await tester.pump();
    c.read(uiBlockStateProvider(_conversation).notifier).write('m1/late', {
      'values': {'a': '旧甲', 'b': '旧乙'},
    });
    await tester.pump();
    expect(find.text('我改的'), findsOneWidget);
    expect(find.text('旧乙'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('picking 其他 again keeps the text still in its field', (tester) async {
    final asked = <String>[];
    await tester.pumpWidget(_host(_block('''
{"component": "form", "id": "o", "fields": [{"key": "g", "label": "性别", "type": "select", "options": ["女", "男"], "required": true}]}'''), onAsk: asked.add));
    await tester.pumpAndSettle();
    await tester.tap(find.text('其他'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '机器人');
    await tester.tap(find.text('其他'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('其他'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('填好了'));
    await tester.pump();
    expect(asked, ['性别：机器人']);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('tabs holding the same component do not share its state; bad props do not throw', (tester) async {
    await tester.pumpWidget(_host(_block('''
{"component": "panel", "children": [{"component": "tabs", "items": ["一", "二"], "children": [
  {"component": "decision-tree", "nodes": [{"id": "a", "text": "甲问", "options": [{"label": "去甲结论", "next": "b"}]}, {"id": "b", "text": "甲结论"}]},
  {"component": "decision-tree", "nodes": [{"id": "x", "text": "乙问", "options": "是"}]}]}]}''')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('去甲结论'));
    await tester.pumpAndSettle();
    expect(find.text('甲结论'), findsOneWidget);
    await tester.tap(find.text('二'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('乙问'), findsOneWidget);
  });

  testWidgets('a set button updates a bound input', (tester) async {
    await tester.pumpWidget(_host(_block('''
{"component": "panel", "state": {"n": 1}, "children": [
  {"component": "input", "bind": "n", "label": "数量", "type": "number"},
  {"component": "button", "label": "设成 2", "set": {"n": 2}}]}''')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '1');
    await tester.tap(find.text('设成 2'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '2');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('screen, storage and set buttons agree on what the block accepts', (tester) async {
    final c = container();
    c.read(uiBlockStateProvider(_conversation).notifier).write('m1/clean', {'n': 'oops', 'gone': 1});
    await tester.pumpWidget(_host(_block('''
{"component": "panel", "id": "clean", "state": {"n": 1}, "children": [
  {"component": "text", "text": "n={n}"},
  {"component": "button", "label": "坏值", "set": {"n": "oops"}},
  {"component": "button", "label": "设 5", "set": {"n": 5}}]}'''), container: c));
    await tester.pumpAndSettle();
    expect(find.text('n=1'), findsOneWidget);
    await tester.tap(find.text('坏值'));
    await tester.pumpAndSettle();
    expect(find.text('n=1'), findsOneWidget);
    expect(c.read(uiBlockStateProvider(_conversation))['m1/clean'], isNull);
    await tester.tap(find.text('设 5'));
    await tester.pumpAndSettle();
    expect(find.text('n=5'), findsOneWidget);
    expect(c.read(uiBlockStateProvider(_conversation))['m1/clean']!.state, {'n': 5});
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a number input shows exactly the value it holds', (tester) async {
    await tester.pumpWidget(_host(_block('''
{"component": "panel", "state": {"n": 1}, "children": [
  {"component": "input", "bind": "n", "label": "数量", "type": "number"},
  {"component": "button", "label": "很小", "set": {"n": 0.0000001}}]}''')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('很小'));
    await tester.pumpAndSettle();
    expect(num.parse(tester.widget<TextField>(find.byType(TextField)).controller!.text), 0.0000001);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a number field keeps only numbers as its answer', (tester) async {
    final c = container();
    await tester.pumpWidget(_host(_block('''
{"component": "form", "id": "num", "fields": [{"key": "age", "label": "年龄", "type": "number"}]}'''), container: c));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'sk-abc');
    await tester.pump();
    expect(c.read(uiBlockStateProvider(_conversation))['m1/num'], isNull);
    await tester.enterText(find.byType(TextField), '18');
    await tester.pump();
    expect(c.read(uiBlockStateProvider(_conversation))['m1/num']!.state, {'values': {'age': 18}});
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('form numbers: shown and sent exactly, non-finite input is not an answer', (tester) async {
    final c = container();
    final asked = <String>[];
    c.read(uiBlockStateProvider(_conversation).notifier).write('m1/n2', {
      'values': {'a': 12.345, 'b': 1000},
    });
    await tester.pumpWidget(_host(_block('''
{"component": "form", "id": "n2", "fields": [{"key": "a", "label": "甲", "type": "number"}, {"key": "b", "label": "乙", "type": "number"},
  {"key": "c", "label": "丙", "type": "number", "required": true}]}'''), container: c, onAsk: asked.add));
    await tester.pumpAndSettle();
    expect(find.text('12.345'), findsOneWidget);
    expect(find.text('1000'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'NaN');
    await tester.tap(find.text('填好了'));
    await tester.pump();
    expect(find.text('这一项要填'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '1e999');
    await tester.tap(find.text('填好了'));
    await tester.pump();
    expect(asked, isEmpty);
    await tester.enterText(find.byType(TextField).last, '0.5');
    await tester.tap(find.text('填好了'));
    await tester.pump();
    expect(asked, ['甲：12.345\n乙：1000\n丙：0.5']);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a slider with huge steps stores its end value without throwing', (tester) async {
    final c = container();
    await tester.pumpWidget(_host(_block('''
{"component": "panel", "id": "big", "state": {"n": 0}, "children": [{"component": "slider", "bind": "n", "label": "大", "min": 0, "max": 1e308, "step": 1e308}]}'''), container: c));
    await tester.pumpAndSettle();
    final slider = find.byType(Slider);
    await tester.tapAt(tester.getTopRight(slider) + const Offset(-2, 10));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(c.read(uiBlockStateProvider(_conversation))['m1/big']!.state, {'n': 1e308});
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('broken bound formulas and infinite numbers render without throwing', (tester) async {
    await tester.pumpWidget(_host(_block('''
{"component": "panel", "computed": {"x": "missing"}, "children": [
  {"component": "input", "bind": "x", "label": "坏"},
  {"component": "input", "type": "number", "value": "{1/0}", "label": "无穷"}]}''')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsNWidgets(2));
  });

  testWidgets('an edited block with a new id starts from fresh answers', (tester) async {
    const form = '{"component": "form", "id": "ID", "fields": [{"key": "a", "label": "甲"}]}';
    await tester.pumpWidget(_host(_block(form.replaceFirst('ID', 'one'))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '旧答案');
    await tester.pump();
    await tester.pumpWidget(_host(_block(form.replaceFirst('ID', 'two'))));
    await tester.pumpAndSettle();
    expect(find.text('旧答案'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('blocks wait for stored answers before taking input', (tester) async {
    SharedPreferences.setMockInitialValues({
      '${UiBlockStateNotifier.prefsPrefix}$_conversation': jsonEncode({
        'm1/stored': {
          'state': {'values': {'a': '旧甲', 'b': '旧乙'}},
        },
      }),
    });
    await tester.pumpWidget(_host(_block('''
{"component": "form", "id": "stored", "fields": [{"key": "a", "label": "甲"}, {"key": "b", "label": "乙"}]}''')));
    expect(find.byType(AbsorbPointer).evaluate().any((e) => (e.widget as AbsorbPointer).absorbing), isTrue);
    // Keyboard focus is held off too, not only taps.
    final editable = tester.widget<EditableText>(find.byType(EditableText).first);
    editable.focusNode.requestFocus();
    await tester.pump(Duration.zero);
    expect(editable.focusNode.hasFocus, isFalse);
    await tester.pumpAndSettle();
    expect(find.text('旧甲'), findsOneWidget);
    expect(find.text('旧乙'), findsOneWidget);
  });

  testWidgets('long options get full rows instead of cut chips', (tester) async {
    await tester.pumpWidget(_host(_block('''
{"component": "decision-tree", "nodes": [
  {"id": "a", "text": "怎么了？", "options": [
    {"label": "嘴上说画好了、还描述了画面，但聊天里没有图", "next": "b"}, {"label": "短", "next": "b"}]},
  {"id": "b", "text": "结论"}]}''')));
    await tester.pumpAndSettle();
    expect(find.byType(UiOptionTile), findsNWidgets(3)); // two options and 其他
    await tester.tap(find.text('嘴上说画好了、还描述了画面，但聊天里没有图'));
    await tester.pumpAndSettle();
    expect(find.text('结论', skipOffstage: false), findsWidgets);
  });

  testWidgets('stat tiles in one line share a height', (tester) async {
    await tester.pumpWidget(_host(_block(_stats), width: 700));
    await tester.pumpAndSettle();
    final a = tester.getSize(find.ancestor(of: find.text('系统提示词'), matching: find.byType(Container)).first);
    final b = tester.getSize(find.ancestor(of: find.text('聊天记录'), matching: find.byType(Container)).first);
    expect(a.height, b.height);
  });

  testWidgets('open fence shows a placeholder; broken JSON falls back', (tester) async {
    await tester.pumpWidget(_host(Column(children: [
      _block('{"component": "checklist", "items": [', closed: false),
      _block('{"component": "checklist", "items": ["cut off'),
      _block('{"component": "rocket"}'),
    ])));
    await tester.pump();
    expect(find.text('正在生成交互组件…'), findsOneWidget);
    expect(find.textContaining('组件没能显示'), findsNWidgets(2));
    expect(find.textContaining('不认识的组件「rocket」'), findsOneWidget);
    await tester.tap(find.text('查看原文').first);
    await tester.pump();
    expect(find.byType(MoeCodeBlock), findsOneWidget);
  });

  testWidgets('raw fallback wraps to the card width', (tester) async {
    tester.view.physicalSize = const Size(375, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final long = '{"component": "rocket", "text": "${'很长的一行原文' * 40}"}';
    for (final document in [false, true]) {
      await tester.pumpWidget(_host(
        MessageBubble(
          isMe: false,
          message: Message(
            id: 'raw-long-$document',
            role: 'assistant',
            content: '```aicove-ui\n$long\n```',
            createdAt: DateTime(2026, 10, 21),
          ),
          documentStyle: document,
        ),
        width: 375,
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看原文'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'document=$document');
      final box = tester.getRect(find.byType(MoeCodeBlock));
      expect(box.right, lessThanOrEqualTo(375), reason: 'document=$document');
      final frame = tester.getRect(find.byType(UiBlockFrame));
      expect(box.right, lessThanOrEqualTo(frame.right), reason: 'document=$document');
      expect(
        find.descendant(of: find.byType(MoeCodeBlock), matching: find.byType(SingleChildScrollView)),
        findsNothing,
        reason: 'document=$document',
      );
      final text = tester.getRect(find.descendant(of: find.byType(MoeCodeBlock), matching: find.byType(RichText)).last);
      expect(text.right, lessThanOrEqualTo(box.right), reason: 'document=$document');
      expect(text.height, greaterThan(100), reason: 'document=$document');
    }
  });

  testWidgets('bubbles render blocks for the assistant, code for the user', (tester) async {
    Message message(String role) => Message(
          id: 'raw-$role',
          role: role,
          content: '先确认三样：\n```aicove-ui\n$_checklist\n```\n都勾上就能打了。',
          createdAt: DateTime(2026, 10, 18),
        );
    for (final document in [false, true]) {
      await tester.pumpWidget(_host(Column(children: [
        MessageBubble(isMe: false, message: message('assistant'), documentStyle: document),
        MessageBubble(isMe: true, message: message('user'), documentStyle: document),
      ])));
      await tester.pumpAndSettle();
      expect(find.byType(MoeUiBlock), findsOneWidget, reason: 'document=$document');
      expect(find.text('语音通话准备'), findsOneWidget);
      expect(find.byType(MoeCodeBlock), findsOneWidget);
    }
  });

  // 源码渲染预览：--dart-define=WRITE_UI_BLOCK_PREVIEW=true 时写到 scratch/ui-blocks-20261018/。
  for (final dark in [false, true]) {
    for (final document in [true, false]) {
      final name = '${document ? 'document' : 'bubble'}-${dark ? 'dark' : 'light'}';
      testWidgets('preview $name', (tester) async {
        if (!_writePreview) return;
        tester.view.physicalSize = const Size(900, 4200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final capture = GlobalKey();
        final reply = Message(
          id: 'raw-preview',
          role: 'assistant',
          content: '语音通话要先配好三样东西，缺哪样补哪样：\n'
              '```aicove-ui\n$_checklist\n```\n'
              '如果角色一直不画画，跟着下面点一下就能找到原因：\n'
              '```aicove-ui\n$_tree\n```\n'
              '```aicove-ui\n$_steps\n```\n'
              '```aicove-ui\n$_stats\n```\n'
              '想知道保留多少轮合适，拖一下试试：\n'
              '```aicove-ui\n$_panel\n```\n'
              '```aicove-ui\n$_quiz\n```',
          createdAt: DateTime(2026, 10, 18),
        );
        await tester.pumpWidget(_host(
          MessageBubble(isMe: false, message: reply, documentStyle: document),
          dark: dark,
          capture: capture,
          width: 420,
        ));
        await tester.pumpAndSettle();
        await tester.tap(find.text('填语音渠道的 Key'));
        await tester.tap(find.text('开了'));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final boundary = capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('../../scratch/ui-blocks-20261018/$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
        });
      });
    }
  }
}

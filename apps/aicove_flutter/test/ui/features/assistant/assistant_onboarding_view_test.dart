import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/assistant/application/assistant_onboarding_controller.dart';
import 'package:aicove_flutter/src/features/assistant/domain/assistant_onboarding.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/assistant/widgets/assistant_onboarding_view.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../features/assistant/assistant_onboarding_test.dart'
    show EmptyConversations, FakeSettings, deepSeek, settingsWith;

const _writePreview = bool.fromEnvironment('WRITE_ASSISTANT_PREVIEW');

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

  Future<FakeSettings> pumpView(
    WidgetTester tester, {
    Map<String, Object> prefs = const {},
    Object? testError,
    bool dark = false,
    GlobalKey? capture,
    Size size = const Size(390, 844),
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = FakeSettings(
      settingsWith([deepSeek()], 'deepseek:deepseek-flash'),
      testError: testError,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWith(() => settings),
          conversationsProvider.overrideWith(EmptyConversations.new),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: dark ? Brightness.dark : Brightness.light,
            fontFamily: _writePreview ? 'Preview' : null,
            extensions: [dark ? MoeColors.dark() : MoeColors.light()],
          ),
          builder: capture == null
              ? null
              : (context, child) =>
                    RepaintBoundary(key: capture, child: child!),
          home: Scaffold(
            body: Stack(
              fit: StackFit.expand,
              children: [
                if (capture != null)
                  Image.asset(
                    'assets/wallpapers/catnap_${dark ? 'dark' : 'light'}.webp',
                    fit: BoxFit.cover,
                    alignment: Alignment.centerLeft,
                  ),
                MoeGlassTheme(
                  enabled: true,
                  blurSigma: kDefaultGlassBlurSigma,
                  child: Consumer(
                    builder: (context, ref, _) =>
                        ref.watch(assistantScriptActiveProvider)
                        ? const AssistantOnboardingView(
                            displayName: 'AIcove酱',
                            avatarUrl:
                                'assets/characters/images/aicove_assistant.png',
                          )
                        : const Center(child: Text('chat list')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (capture != null) {
      await tester.runAsync(() async {
        for (final element in find.byType(Image).evaluate()) {
          await precacheImage((element.widget as Image).image, element);
        }
      });
      await tester.pumpAndSettle();
    }
    return settings;
  }

  testWidgets('experienced users go straight to pasting a key', (tester) async {
    await pumpView(
      tester,
      testError: Exception('模型测试失败: Exception: HTTP 401: invalid'),
    );
    expect(
      find.textContaining('你之前配置过 API、用过 AI Agent 吗？', findRichText: true),
      findsOneWidget,
    );

    await tester.tap(find.text('配过 API，直接填 Key'));
    await tester.pumpAndSettle();
    expect(find.textContaining('用哪家模型服务？', findRichText: true), findsOneWidget);
    expect(find.text('API 是什么？'), findsNothing);

    await tester.tap(find.text('DeepSeek（推荐）'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('assistant-onboarding-key-field')),
      'sk-wrong',
    );
    await tester.tap(find.text('保存并测试'));
    await tester.pumpAndSettle();

    expect(
      find.text(keyCheckFailureMessage(KeyCheckFailure.invalidKey)),
      findsOneWidget,
    );
    expect(find.text('换一家'), findsOneWidget);
  });

  testWidgets('a working key leaves the script for the chat', (tester) async {
    final settings = await pumpView(
      tester,
      prefs: {
        AssistantOnboardingController.prefsKey:
            '{"step":"pasteKey","experienced":true,"outcome":"pending"}',
      },
    );
    await tester.enterText(
      find.byKey(const ValueKey('assistant-onboarding-key-field')),
      'sk-good',
    );
    await tester.tap(find.text('保存并测试'));
    await tester.pumpAndSettle();

    expect(settings.savedKeys, [
      ['sk-good'],
    ]);
    expect(find.text('chat list'), findsOneWidget);
  });

  testWidgets('skipping everything leaves the script for good', (tester) async {
    await pumpView(tester);
    await tester.tap(find.text('都会，跳过全部教程'));
    await tester.pumpAndSettle();
    expect(find.text('chat list'), findsOneWidget);
  });

  for (final dark in [false, true]) {
    for (final step in [
      ('experience', false, null),
      ('chooseProvider', false, 'API 是什么？'),
      ('getKey', false, null),
      ('pasteKey', false, 'fail'),
      ('chooseProvider', false, 'wide'),
    ]) {
      final wide = step.$3 == 'wide';
      final name =
          '${step.$1}-${dark ? 'dark' : 'light'}${wide ? '-wide' : ''}';
      testWidgets('preview $name', (tester) async {
        if (!_writePreview) return;
        final capture = GlobalKey();
        await pumpView(
          tester,
          dark: dark,
          capture: capture,
          size: wide ? const Size(760, 844) : const Size(390, 844),
          testError: Exception(
            '模型测试失败: Exception: HTTP 402: Insufficient Balance',
          ),
          prefs: {
            AssistantOnboardingController.prefsKey:
                '{"step":"${step.$1}","experienced":${step.$2},"outcome":"pending"}',
          },
        );
        if (step.$3 == 'fail') {
          await tester.enterText(
            find.byKey(const ValueKey('assistant-onboarding-key-field')),
            'sk-0123456789',
          );
          await tester.tap(find.text('保存并测试'));
          await tester.pumpAndSettle();
        } else if (step.$3 != null && !wide) {
          await tester.tap(find.text(step.$3!));
          await tester.pumpAndSettle();
        }
        await tester.runAsync(() async {
          final boundary =
              capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '../../scratch/assistant-onboarding-20261021/$name.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
        });
      });
    }
  }
}

import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/plugins/tts/voice_preset_application.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/settings/data/support/ui_models_store_support.dart';
import 'package:aicove_flutter/src/features/voice_call/domain/asr_request_format.dart';
import 'package:aicove_flutter/src/features/voice_call/providers/voice_call_settings.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/tts_plugin_detail_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/add_provider_sheet.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/provider_detail_page.dart';
import 'package:aicove_flutter/src/ui/features/voice_call/pages/voice_call_settings_page.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Settings extends AppSettingsNotifier {
  _Settings([this.data = const <String, dynamic>{}]);
  final Map<String, dynamic> data;

  @override
  Future<AppSettings> build() async => mapUiModelsToAppSettings(data);
}

/// 渠道详情预览用：内置阿里云（合成＋识别）与腾讯云识别渠道。
Map<String, dynamic> _providerData() => normalizeUiModelsStoreData({
  'providers': [
    {
      'id': 'tencent_asr',
      'displayName': '腾讯云',
      'apiKeys': ['secret-key'],
      'apiBaseUrl': 'wss://asr.cloud.tencent.com/asr/v2',
      'enabled': true,
      'models': ['16k_zh', '16k_zh_en', 'Hy-ASR-3.0-preview'],
      'visible_models': ['16k_zh', '16k_zh_en', 'Hy-ASR-3.0-preview'],
      'capabilities': ['stt'],
      'custom_config': {
        'asrRequestFormat': 'tencent_asr',
        'asr_app_id': '1259000000',
      },
    },
  ],
});

class _FakeInstall extends LocalCallModelInstallNotifier {
  _FakeInstall([this.initial = const LocalCallModelInstallState()]);

  final LocalCallModelInstallState initial;
  int installs = 0;

  @override
  LocalCallModelInstallState build() => initial;

  @override
  Future<void> install() async {
    installs++;
    state = const LocalCallModelInstallState(
      downloading: true,
      received: 60 * 1024 * 1024,
      total: 228 * 1024 * 1024,
    );
  }
}

const _aliyun = ProviderAuth(
  id: 'aliyun',
  displayName: '阿里云',
  apiKeys: ['k'],
  apiBaseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
  customConfig: {'asrRequestFormat': 'aliyun_asr'},
);
const _tencent = ProviderAuth(
  id: 'tencent_asr',
  displayName: '腾讯云',
  apiKeys: ['k'],
  apiBaseUrl: 'wss://asr.cloud.tencent.com/asr/v2',
  customConfig: {'asrRequestFormat': 'tencent_asr'},
);
const _cloudOptions = <CloudRecognizerOption>[
  CloudRecognizerOption(
    provider: _aliyun,
    model: 'fun-asr-realtime',
    format: AsrRequestFormat.aliyun,
  ),
  CloudRecognizerOption(
    provider: _tencent,
    model: '16k_zh',
    format: AsrRequestFormat.tencent,
    missing: 'SecretId',
  ),
];

void main() {
  const capture = bool.fromEnvironment('WRITE_VOICE_CALL_PREVIEW');

  Future<void> mount(
    WidgetTester tester,
    Widget page, {
    Size size = const Size(360, 720),
    GlobalKey? boundary,
    _FakeInstall? install,
    List<CloudRecognizerOption>? cloud,
    Map<String, dynamic>? settings,
  }) async {
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          appSettingsProvider.overrideWith(
            () => _Settings(settings ?? const <String, dynamic>{}),
          ),
          voicePresetReadyProvider.overrideWith((ref) async {}),
          localCallModelInstallProvider.overrideWith(
            () => install ?? _FakeInstall(),
          ),
          callRecognizerReadinessProvider.overrideWith(
            (ref) async => CallRecognizerReadiness(
              localInstalled: false,
              cloud: cloud ?? _cloudOptions,
            ),
          ),
        ],
        child: SkinScope(
          skin: const MoeTalkSkin(),
          child: MaterialApp(
            theme: ThemeData(
              fontFamily: capture ? 'Preview' : null,
              extensions: [MoeColors.light()],
            ),
            home: RepaintBoundary(key: boundary, child: page),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the voice plugin page opens the call settings', (tester) async {
    await mount(tester, const TtsPluginDetailPage());
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('语音通话'));
    await tester.pumpAndSettle();
    expect(find.byType(VoiceCallSettingsPage), findsOneWidget);
  });

  testWidgets('recognizer source defaults to auto and is kept on this device', (
    tester,
  ) async {
    await mount(tester, const VoiceCallSettingsPage());
    expect(tester.takeException(), isNull);
    expect(find.text('本地模型未安装，当前会用 阿里云 · fun-asr-realtime'), findsOneWidget);
    expect(find.text('还缺 SecretId，请在渠道商里填写'), findsOneWidget);
    Finder checkIn(String label) => find.descendant(
      of: find.ancestor(
        of: find.text(label),
        matching: find.byType(MoeSettingsRow),
      ),
      matching: find.byIcon(Icons.check),
    );
    expect(checkIn('自动'), findsOneWidget);

    await tester.tap(find.text('阿里云 · fun-asr-realtime'));
    await tester.pumpAndSettle();
    expect(checkIn('阿里云 · fun-asr-realtime'), findsOneWidget);
    expect(checkIn('自动'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(
      CallRecognizerSource.decode(
        prefs.getString('aicove.voice_call.recognizer_source.v2'),
      ),
      const CallRecognizerSource.cloud('aliyun', 'fun-asr-realtime'),
    );
  });

  testWidgets('without ASR providers the list offers to add one', (
    tester,
  ) async {
    await mount(tester, const VoiceCallSettingsPage(), cloud: const []);
    expect(find.text('本地模型和语音识别渠道都还不可用'), findsOneWidget);
    await tester.tap(find.text('添加语音识别渠道'));
    await tester.pumpAndSettle();
    expect(find.text('添加供应商'), findsOneWidget);
    expect(find.text('火山引擎（豆包）'), findsOneWidget);
    expect(find.text('SecretKey'), findsNothing);
  });

  testWidgets('choosing the local model offers to download it', (tester) async {
    final install = _FakeInstall();
    await mount(tester, const VoiceCallSettingsPage(), install: install);
    expect(find.text('下载本地识别模型'), findsOneWidget);

    await tester.tap(find.text('本地模型'));
    await tester.pumpAndSettle();
    expect(find.textContaining('本地模型还没有安装'), findsOneWidget);
    await tester.tap(find.text('下载').last);
    await tester.pumpAndSettle();

    expect(install.installs, 1);
    expect(find.text('正在下载 26%'), findsOneWidget);
    expect(find.text('60 / 228 MB'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('a failed download shows the reason and retries on tap', (
    tester,
  ) async {
    final install = _FakeInstall(
      const LocalCallModelInstallState(error: '网络连接失败'),
    );
    await mount(tester, const VoiceCallSettingsPage(), install: install);
    expect(find.text('下载失败，点按重试'), findsOneWidget);
    expect(find.text('网络连接失败'), findsOneWidget);
    await tester.tap(find.text('下载失败，点按重试'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载').last);
    await tester.pumpAndSettle();
    expect(install.installs, 1);
  });

  testWidgets('voice call settings source rendered preview', (tester) async {
    if (!capture) return;
    await tester.runAsync(() async {
      final loader = FontLoader('Preview')
        ..addFont(
          File(
            '/System/Library/Fonts/STHeiti Medium.ttc',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File(
            '${Platform.environment['HOME']}/dev-sdks/flutter-3.44.6/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await icons.load();
    });
    for (final (name, page, install, prepare) in [
      ('voice-plugin', const TtsPluginDetailPage() as Widget, null, null),
      ('voice-call-settings', const VoiceCallSettingsPage(), null, null),
      (
        'voice-call-settings-downloading',
        const VoiceCallSettingsPage(),
        _FakeInstall(
          const LocalCallModelInstallState(
            downloading: true,
            received: 60 * 1024 * 1024,
            total: 228 * 1024 * 1024,
          ),
        ),
        null,
      ),
      (
        'add-provider-asr-tencent',
        const Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: AddProviderSheet(initialCategory: ProviderCategory.stt),
          ),
        ),
        null,
        () async {
          await tester.tap(find.text('腾讯云').first);
          await tester.pumpAndSettle();
        },
      ),
      (
        'provider-detail-tencent-asr',
        const ProviderDetailPage(providerId: 'tencent_asr'),
        null,
        null,
      ),
    ]) {
      final key = GlobalKey();
      await mount(
        tester,
        page,
        size: const Size(390, 760),
        boundary: key,
        install: install,
        settings: name.startsWith('provider-detail') ? _providerData() : null,
      );
      await prepare?.call();
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final dir = Directory('../../.codex-temp/voice-call/previews')
          ..createSync(recursive: true);
        await File(
          '${dir.path}/$name-390.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/sync/domain/lan_contract.dart';
import 'package:aicove_flutter/src/features/sync/domain/lan_sync_port.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_transport.dart';
import 'package:aicove_flutter/src/features/sync/providers/lan_sync_provider.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/lan_sync_page.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';

class PreviewLanPort implements LanSyncPort {
  PreviewLanPort(this.state);
  @override
  LanSyncState state;
  final _changes = StreamController<LanSyncState>.broadcast();
  final actions = <String>[];
  @override
  Stream<LanSyncState> get changes => _changes.stream;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> close() => _changes.close();
  @override
  Future<void> setEnabled(bool value) async {
    actions.add('enabled:$value');
  }

  @override
  Future<void> setName(String value) async {
    actions.add('name:$value');
  }

  @override
  Future<void> invite() async {
    actions.add('invite');
  }

  @override
  Future<void> pair(String value) async {
    actions.add('pair:$value');
  }

  @override
  Future<String> decodeQr(Uint8List bytes) async => 'code';
  @override
  Future<void> approve(String id) async {
    actions.add('approve:$id');
  }

  @override
  Future<void> forget(String id) async {
    actions.add('forget:$id');
  }

  @override
  Future<void> synchronize() async {
    actions.add('sync');
  }

  @override
  Future<void> resolve(LanRevision selected, List<String> hashes) async {
    actions.add('resolve:${selected.hash}');
  }

  @override
  Future<void> foreground(bool active) async {}
}

void main() {
  const capture = bool.fromEnvironment('WRITE_LAN_PREVIEW');
  Future<void> mount(
    WidgetTester tester,
    PreviewLanPort port,
    double width, {
    GlobalKey? boundary,
  }) async {
    tester.view.physicalSize = Size(width, 980);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(port.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          lanSyncPortProvider.overrideWith((ref) async => port),
          lanSyncStateProvider.overrideWith((ref) async* {
            yield port.state;
            yield* port.changes;
          }),
        ],
        child: SkinScope(
          skin: const MoeTalkSkin(),
          child: MaterialApp(
            theme: ThemeData(
              fontFamily: capture ? 'Preview' : null,
              extensions: [MoeColors.light()],
            ),
            home: RepaintBoundary(key: boundary, child: const LanSyncPage()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final width in [360.0, 1040.0]) {
    testWidgets('shared LAN page actions and no overflow at $width', (
      tester,
    ) async {
      final port = PreviewLanPort(
        const LanSyncState(
          enabled: true,
          name: '我的电脑',
          peers: [LanPeerView('phone', '我的手机', pending: true, incoming: true)],
        ),
      );
      await mount(tester, port, width);
      expect(find.text('局域网同步'), findsOneWidget);
      await tester.tap(find.text('显示配对二维码'));
      await tester.pumpAndSettle();
      expect(port.actions, contains('invite'));
      await tester.ensureVisible(find.text('确认配对'));
      await tester.tap(find.text('确认配对'));
      await tester.pumpAndSettle();
      expect(port.actions, contains('approve:phone'));
      await tester.tap(find.text('取消配对'));
      await tester.pumpAndSettle();
      expect(find.text('取消与我的手机的配对？'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '保留'));
      await tester.pumpAndSettle();
      expect(port.actions.any((a) => a.startsWith('forget:')), false);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('LAN page supports large text and name edits auto-save', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final port = PreviewLanPort(const LanSyncState(enabled: true, name: '电脑'));
    await mount(tester, port, 360);
    await tester.enterText(find.byType(TextField).first, '家里的电脑');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(port.actions, contains('name:家里的电脑'));
    expect(find.text('保存名称'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'joining device waits for remote confirmation instead of approving itself',
    (tester) async {
      final port = PreviewLanPort(
        const LanSyncState(
          enabled: true,
          name: '手机',
          peers: [LanPeerView('pc', '电脑', pending: true)],
        ),
      );
      await mount(tester, port, 360);
      expect(find.text('等待对方确认'), findsOneWidget);
      expect(find.text('确认配对'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'conflict choice passes all preview hashes and correct complete revision',
    (tester) async {
      final a = LanRevision(
        kind: 'messages',
        id: 'id',
        vector: {'a': 1},
        payload: {
          'row': {'content': '手机编辑'},
        },
      );
      final b = LanRevision(
        kind: 'messages',
        id: 'id',
        vector: {'b': 1},
        payload: {
          'row': {'content': '电脑编辑'},
        },
      );
      final port = PreviewLanPort(
        LanSyncState(
          enabled: true,
          name: '电脑',
          conflicts: [
            [a, b],
          ],
        ),
      );
      await mount(tester, port, 360);
      await tester.ensureVisible(find.text('聊天同时被修改'));
      await tester.tap(find.text('聊天同时被修改'));
      await tester.pumpAndSettle();
      expect(find.text('手机编辑'), findsWidgets);
      expect(find.text('电脑编辑'), findsOneWidget);
      await tester.tap(find.text('采用这一份').last);
      await tester.pumpAndSettle();
      expect(port.actions, contains('resolve:${b.hash}'));
      expect(tester.takeException(), isNull);
    },
  );
  for (final width in [360.0, 1040.0]) {
    testWidgets('LAN source rendered preview $width', (tester) async {
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
      final key = GlobalKey();
      final code = LanInvitation(
        'preview-device',
        '我的电脑',
        base64UrlPreviewKey,
        DateTime.now().add(const Duration(minutes: 10)),
        [const LanEndpoint('192.168.1.10', 40123)],
      ).code;
      final port = PreviewLanPort(
        LanSyncState(
          enabled: true,
          name: '我的电脑',
          invitation: width == 1040 ? code : null,
          peers: [
            LanPeerView(
              'phone',
              '我的手机',
              online: true,
              lastSync: DateTime(2026, 10, 1, 14, 30),
            ),
          ],
          notice: '两端连接同一 Wi-Fi 或热点，打开应用即可同步',
        ),
      );
      await mount(tester, port, width, boundary: key);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final dir = Directory('../../.codex-temp/lan-sync/previews')
          ..createSync(recursive: true);
        await File(
          '${dir.path}/lan-${width.toInt()}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    });
  }
}

const base64UrlPreviewKey = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

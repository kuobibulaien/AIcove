import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/account/domain/account_port.dart';
import 'package:aicove_flutter/src/features/account/providers/account_provider.dart';
import 'package:aicove_flutter/src/features/sync/domain/lan_sync_port.dart';
import 'package:aicove_flutter/src/features/sync/models/user_model.dart';
import 'package:aicove_flutter/src/features/sync/providers/cloud_sync_provider.dart';
import 'package:aicove_flutter/src/features/sync/providers/lan_sync_provider.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/account_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/cloud_conflicts_page.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';

class FakeCloud extends CloudSyncController {
  FakeCloud(super.ref) {
    state = const CloudProgress(
      '有 350 项同时修改，两个版本均已保留',
      enabled: true,
      conflicts: 350,
    );
  }
  Map<String, bool>? resolved;

  @override
  String? get deviceId => 'mac';

  @override
  Future<Map<String, dynamic>> conflicts() async => {
    'cursor': 9,
    'epoch': 'e',
    'conflicts': [
      for (var i = 0; i < 350; i++)
        {'conflict_id': 'c$i', 'device_id': i < 300 ? 'mac' : 'phone'},
    ],
  };

  @override
  Future<void> resolveAll(
    Map<String, dynamic> preview,
    Map<String, bool> useIncoming, {
    void Function(int done, int total)? onProgress,
  }) async {
    resolved = useIncoming;
  }
}

class SignedInAccount implements AccountPort {
  @override
  final connection = AccountConnection(
    server: 'https://example.invalid',
    user: UserModel(id: 1, username: 'preview'),
    token: 'token',
  );
  @override
  Future<void> load() async {}
  @override
  Future<void> refresh() async {}
  @override
  Future<void> login(String server, String username, String password) async {}
  @override
  Future<void> logout() async {}
}

void main() {
  const capture = bool.fromEnvironment('WRITE_CLOUD_PREVIEW');
  late FakeCloud cloud;

  Future<void> mount(WidgetTester tester, Widget page, {GlobalKey? key}) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          cloudSyncProvider.overrideWith((ref) => cloud = FakeCloud(ref)),
          accountRepositoryProvider.overrideWithValue(SignedInAccount()),
          lanSyncStateProvider.overrideWith(
            (ref) => Stream.value(
              const LanSyncState(
                name: 'MacBook Pro',
                peers: [LanPeerView('phone', '一加 13T')],
              ),
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
            home: RepaintBoundary(key: key, child: page),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('sync actions share one button style and spacing', (
    tester,
  ) async {
    await mount(tester, const AccountPage());
    final labels = ['立即同步', '处理同时修改', '暂停自动同步'];
    final boxes = [
      for (final label in labels) tester.getRect(find.text(label)),
    ];
    expect(
      find.byType(TextButton).evaluate().where((e) {
        final child = (e.widget as TextButton).child;
        return child is Text && labels.contains(child.data);
      }),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
    expect(boxes[1].top - boxes[0].top, boxes[2].top - boxes[1].top);
  });

  testWidgets('choosing a device resolves every conflict at once', (
    tester,
  ) async {
    await mount(tester, const CloudConflictsPage());
    expect(find.text('本机 · MacBook Pro'), findsOneWidget);
    expect(find.text('一加 13T'), findsOneWidget);
    expect(find.text('云端最后状态'), findsOneWidget);
    expect(find.textContaining('c1'), findsNothing);
    await tester.tap(find.text('以此设备为准处理差异').at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始处理'));
    await tester.pumpAndSettle();
    expect(cloud.resolved, hasLength(350));
    expect(cloud.resolved!.values.where((v) => v), hasLength(50));
    expect(cloud.resolved!['c349'], isTrue);
    expect(cloud.resolved!['c0'], isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final (name, page) in [
    ('account', const AccountPage()),
    ('conflicts', const CloudConflictsPage()),
  ]) {
    testWidgets('cloud source rendered preview $name', (tester) async {
      if (!capture) return;
      await tester.runAsync(() async {
        final loader = FontLoader('Preview')
          ..addFont(
            File(
              '/System/Library/Fonts/STHeiti Medium.ttc',
            ).readAsBytes().then(ByteData.sublistView),
          );
        await loader.load();
      });
      final key = GlobalKey();
      await mount(tester, page, key: key);
      if (name == 'account') {
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
        await tester.pumpAndSettle();
      }
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final dir = Directory('../../.codex-temp/cloud-sync/previews')
          ..createSync(recursive: true);
        await File(
          '${dir.path}/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    });
  }
}

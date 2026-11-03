import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/features/account/domain/account_port.dart';
import 'package:aicove_flutter/src/features/account/providers/account_provider.dart';
import 'package:aicove_flutter/src/features/sync/models/user_model.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/account_page.dart';
import 'package:aicove_flutter/src/ui/features/backup/pages/data_management_page.dart';
import 'package:aicove_flutter/src/ui/features/debug/pages/debug_center_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/settings_page.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

class FixtureAccount implements AccountPort {
  @override
  AccountConnection? connection;
  @override
  Future<void> load() async {}
  @override
  Future<void> refresh() async {}
  @override
  Future<void> login(String server, String username, String password) async {
    connection = AccountConnection(
      server: server,
      user: UserModel(id: 12, username: username),
      token: 'fixture',
    );
  }

  @override
  Future<void> logout() async {
    connection = AccountConnection(
      server: connection!.server,
      user: connection!.user,
    );
  }
}

void main() {
  testWidgets('account lives under debug sync and backup, not settings root', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(390, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountRepositoryProvider.overrideWithValue(FixtureAccount()),
        ],
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('账号'), findsNothing);
    expect(find.text('局域网同步'), findsNothing);
    await tester.tap(find.text('调试'));
    await tester.pumpAndSettle();
    expect(find.byType(DebugCenterPage), findsOneWidget);
    await tester.tap(find.text('同步与备份'));
    await tester.pumpAndSettle();
    expect(find.byType(DataManagementPage), findsOneWidget);
    expect(find.text('局域网同步'), findsOneWidget);
    expect(find.text('导出数据'), findsOneWidget);
    expect(
      tester.getRect(find.text('局域网同步')).top,
      lessThan(tester.getRect(find.text('云同步')).top),
    );
    await tester.tap(find.text('云同步'));
    await tester.pumpAndSettle();
    expect(find.byType(AccountPage), findsOneWidget);
    expect(find.text('登录你的账号'), findsOneWidget);
    expect(find.text('去用局域网同步（首选）'), findsOneWidget);
    expect(find.text('自建服务器与 AI 辅助部署'), findsOneWidget);
    await tester.tap(find.text('自建服务器与 AI 辅助部署'));
    await tester.pumpAndSettle();
    expect(find.text('复制 AI 辅助部署提示词'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final size in [const Size(360, 780), const Size(1100, 820)]) {
    testWidgets('account login, ID, logout preserve owner at $size', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final account = FixtureAccount();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [accountRepositoryProvider.overrideWithValue(account)],
          child: const MaterialApp(home: AccountPage()),
        ),
      );
      await tester.pumpAndSettle();
      final user = find.descendant(
        of: find.byKey(const ValueKey('account-username')),
        matching: find.byType(TextField),
      );
      final password = find.descendant(
        of: find.byKey(const ValueKey('account-password')),
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(password).obscureText, false);
      await tester.enterText(user, 'fixture');
      await tester.enterText(password, 'test-password');
      await tester.ensureVisible(find.text('登录').last);
      await tester.tap(find.text('登录').last);
      await tester.pumpAndSettle();
      expect(find.text('已登录'), findsOneWidget);
      expect(find.text('账号 ID'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      expect(find.text('test-password'), findsNothing);
      await tester.ensureVisible(find.text('退出登录'));
      await tester.tap(find.text('退出登录'));
      await tester.pumpAndSettle();
      expect(account.connection!.hasSession, false);
      expect(find.text('12'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('source rendered preview for sync entry and self-hosted guide', (
    tester,
  ) async {
    const capture = bool.fromEnvironment('WRITE_SYNC_ENTRY_PREVIEW');
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
    final dir = Directory('../../scratch/sync-entry-previews')
      ..createSync(recursive: true);

    for (final (name, page, scrollY) in [
      ('data_management', const DataManagementPage(), 0.0),
      ('account_top', const AccountPage(), 0.0),
      ('account_guide', const AccountPage(), -420.0),
    ]) {
      final key = GlobalKey();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accountRepositoryProvider.overrideWithValue(FixtureAccount()),
          ],
          child: SkinScope(
            skin: const MoeTalkSkin(),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                fontFamily: 'Preview',
                extensions: [MoeColors.light()],
              ),
              home: RepaintBoundary(key: key, child: page),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (name == 'account_guide') {
        await tester.tap(find.text('自建服务器与 AI 辅助部署'));
        await tester.pumpAndSettle();
      }
      if (scrollY != 0) {
        await tester.drag(
          find.byType(Scrollable).first,
          Offset(0, scrollY),
        );
        await tester.pumpAndSettle();
      }
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '${dir.path}/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}

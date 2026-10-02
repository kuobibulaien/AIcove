import 'package:flutter/material.dart';
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
    await tester.tap(find.text('云同步'));
    await tester.pumpAndSettle();
    expect(find.byType(AccountPage), findsOneWidget);
    expect(find.text('登录你的账号'), findsOneWidget);
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
}

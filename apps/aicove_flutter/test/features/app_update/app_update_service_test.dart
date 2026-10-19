import 'dart:convert';

import 'package:aicove_flutter/src/features/app_update/app_update_dialog.dart';
import 'package:aicove_flutter/src/features/app_update/app_update_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, Object?> _release(String tag, {bool draft = false}) => {
      'tag_name': tag,
      'body': '新增与改进：\n- notes for $tag',
      'html_url': 'https://github.com/kuobibulaien/AIcove/releases/tag/$tag',
      'draft': draft,
      'prerelease': true,
    };

AppUpdateService _service(
  List<Map<String, Object?>> releases, {
  String current = '0.1.0-test.4',
  int status = 200,
}) {
  return AppUpdateService(
    currentVersion: current,
    client: MockClient(
      (_) async => http.Response.bytes(utf8.encode(jsonEncode(releases)), status),
    ),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('compares versions with pre-release identifiers', () {
    expect(compareReleaseVersions('0.1.0-test.10', '0.1.0-test.9'), 1);
    expect(compareReleaseVersions('v0.1.0', '0.1.0-test.9'), 1);
    expect(compareReleaseVersions('0.2.0-test.1', '0.1.0'), 1);
    expect(compareReleaseVersions('0.1.0-test.4+5', '0.1.0-test.4'), 0);
    expect(compareReleaseVersions('0.1.0-test', '0.1.0-test.1'), -1);
    expect(compareReleaseVersions('build-7c84b2df9', '0.1.0'), isNull);
  });

  test('condenses release notes to first clauses of the change list', () {
    const body = '''AIcove 0.1.0 · 公开测试版 4

新增与改进：
- Agent 运行时：新增纯 Dart 内核，后台任务与前台聊天可切换到内核执行（默认仍走原链路）；预设脚本迁入内核。
- 同步：发送中的消息不再同步到其它设备；应用异常退出后自动恢复。
- 界面：新安装默认使用推荐的毛玻璃材质。

验证：完整 Flutter 套件 2634 通过、18 失败。

下载：
- Android APK：0.1.0，构建号 2026100801。''';
    expect(releaseHighlights(body), [
      'Agent 运行时：新增纯 Dart 内核',
      '同步：发送中的消息不再同步到其它设备',
      '界面：新安装默认使用推荐的毛玻璃材质',
    ]);
    expect(releaseHighlights('- a\n- b\n- c', limit: 2), ['a', 'b']);
    expect(releaseHighlights('只有一段说明'), isEmpty);
  });

  test('picks the highest non-draft versioned release', () async {
    final latest = await _service([
      _release('v0.1.0-test.6', draft: true),
      _release('build-7c84b2df9'),
      _release('v0.1.0-test.4'),
      _release('v0.1.0-test.5'),
      _release('v0.0.0-preview.20260918'),
    ]).fetchLatest();
    expect(latest?.version, '0.1.0-test.5');
    expect(latest?.highlights, ['notes for v0.1.0-test.5']);
    expect(latest?.url, endsWith('/v0.1.0-test.5'));
  });

  test('reports only newer releases', () async {
    expect(
      (await _service([_release('v0.1.0-test.5')]).checkForUpdate())?.version,
      '0.1.0-test.5',
    );
    expect(await _service([_release('v0.1.0-test.4')]).checkForUpdate(),
        isNull);
  });

  test('automatic check honours skipped version, manual check does not',
      () async {
    await AppUpdateService.skipVersion('0.1.0-test.5');
    final releases = [_release('v0.1.0-test.5')];
    expect(await _service(releases).checkForUpdate(), isNull);
    expect(
      (await _service(releases).checkForUpdate(manual: true))?.version,
      '0.1.0-test.5',
    );
    // A later release prompts again.
    expect(
      (await _service([_release('v0.1.0-test.6')]).checkForUpdate())?.version,
      '0.1.0-test.6',
    );
  });

  test('development builds compare package version and build number',
      () async {
    AppUpdateService dev(List<(String, int?)> releases) => AppUpdateService(
          currentVersion: '',
          packageVersion: '0.3.0',
          packageBuildNumber: '2026101602',
          client: MockClient(
            (_) async => http.Response.bytes(
              utf8.encode(jsonEncode([
                for (final (tag, build) in releases)
                  {
                    ..._release(tag),
                    if (build != null)
                      'body': '新增与改进：\n- notes\n\n构建号 $build；',
                  },
              ])),
              200,
            ),
          ),
        );

    expect(dev(const []).isDevelopmentBuild, isTrue);
    expect(dev(const []).canCheck, isTrue);
    // A higher core is newer whatever its build number.
    expect((await dev([('v0.4.0-test.1', null)]).checkForUpdate())?.version,
        '0.4.0-test.1');
    // The same core is newer only when built later than this build.
    expect(
        (await dev([('v0.3.0-test.2', 2026101701)]).checkForUpdate())?.version,
        '0.3.0-test.2');
    expect(await dev([('v0.3.0-test.1', 2026101602)]).checkForUpdate(), isNull);
    expect(await dev([('v0.3.0-test.1', null)]).checkForUpdate(), isNull);
    // Older lines are never offered.
    expect(await dev([('v0.2.0-test.5', 2026101801)]).checkForUpdate(), isNull);
  });

  test('development builds honour the skipped version automatically',
      () async {
    final service = AppUpdateService(
      currentVersion: '',
      packageVersion: '0.2.0',
      client: MockClient(
        (_) async => http.Response.bytes(
          utf8.encode(jsonEncode([_release('v0.3.0-test.1')])),
          200,
        ),
      ),
    );
    await AppUpdateService.skipVersion('0.3.0-test.1');
    expect(await service.checkForUpdate(), isNull);
    expect((await service.checkForUpdate(manual: true))?.version,
        '0.3.0-test.1');
  });

  test('reads the build number from release notes', () {
    expect(releaseBuildNumber('- Android APK：0.3.0，构建号 2026101602；'),
        2026101602);
    expect(releaseBuildNumber('no number'), isNull);
  });

  test('builds without any version never pretend to be up to date', () async {
    final service = _service([_release('v9.0.0')], current: '');
    expect(service.canCheck, isFalse);
    expect(await service.checkForUpdate(), isNull);
    expect(service.checkForUpdate(manual: true), throwsA(anything));
  });

  test('describes the installed version for release and dev builds', () {
    expect(describeInstalledVersion('0.3.0-test.1'), '0.3.0-test.1');
    expect(describeInstalledVersion('v0.3.0'), '0.3.0');
    expect(describeInstalledVersion('', numeric: '0.3.0'), '开发版 0.3.0');
    expect(describeInstalledVersion(''), '开发版本');
  });

  test('automatic check swallows errors, manual check rethrows', () async {
    final service = _service(const [], status: 403);
    expect(await service.checkForUpdate(), isNull);
    expect(service.checkForUpdate(manual: true), throwsA(isA<Exception>()));
  });

  testWidgets('skip action remembers the release version', (tester) async {
    const release = AppRelease(
      version: '0.1.0-test.5',
      highlights: ['更新检测：启动时提示新版本'],
      url: 'https://github.com/kuobibulaien/AIcove/releases/tag/v0.1.0-test.5',
    );
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showAppUpdateDialog(context, release,
              currentVersion: '0.1.0-test.4'),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.text('0.1.0-test.5（当前 0.1.0-test.4）'), findsOneWidget);
    expect(find.text('· 更新检测：启动时提示新版本'), findsOneWidget);
    expect(find.text('稍后'), findsOneWidget);
    expect(find.text('前往下载'), findsOneWidget);

    await tester.tap(find.text('跳过此版本'));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本'), findsNothing);
    expect(await AppUpdateService.skippedVersion(), '0.1.0-test.5');
  });
}

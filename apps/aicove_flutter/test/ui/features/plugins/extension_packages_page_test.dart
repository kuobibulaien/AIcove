import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/plugins/packages/package_providers.dart';
import 'package:aicove_flutter/src/features/plugins/packages/package_store.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/extension_packages_page.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../features/plugins/packages/extension_test_support.dart';

/// 扩展包页：列表、zip 导入、长按删除。
///
/// 带 `--dart-define=WRITE_EXTENSION_QA=true` 时把页面渲染成 PNG 写入
/// `scratch/extension-packages/`（源码渲染预览）。
class _Picker extends FilePicker {
  List<int> zipBytes = const [];

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => FilePickerResult([
    PlatformFile(
      name: 'skill.zip',
      size: zipBytes.length,
      bytes: Uint8List.fromList(zipBytes),
    ),
  ]);
}

/// Records deletions without file I/O; real deletion is covered by the
/// package store tests.
class _RecordingPackages extends AicovePackagesNotifier {
  _RecordingPackages(super.store);
  final deleted = <String>[];

  @override
  Future<void> delete(String id) async {
    deleted.add(id);
    state = [for (final p in state) if (p.id != id) p];
  }
}

void main() {
  const capture = bool.fromEnvironment('WRITE_EXTENSION_QA');
  final picker = _Picker();
  late Directory root;
  late PackageStore store;

  setUpAll(() async {
    FilePicker.platform = picker;
    if (!capture) return;
    final font = FontLoader('ExtensionPreview')
      ..addFont(
        File(
          '/System/Library/Fonts/STHeiti Medium.ttc',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        File(
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await icons.load();
  });

  // Seeded in real time: the store's per-root lock chain must not be created
  // inside the widget test's fake clock, or later reads wait on it forever.
  Future<void> seed(WidgetTester tester) => tester.runAsync(() async {
    root = await Directory.systemTemp.createTemp('extension_page');
    store = PackageStore(root);
    await store.importFiles(skillFiles(name: 'Weekly Report'));
    await store.importFiles(scriptFiles(scriptSource, id: 'calculator'));
    addTearDown(() => root.delete(recursive: true));
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
    }
  }

  Future<GlobalKey> pumpPage(
    WidgetTester tester, {
    double width = 390,
    bool dark = false,
    AicovePackagesNotifier Function(Future<PackageStore>)? notifier,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 700);
    final key = GlobalKey();
    // Each scope disposes its notifier, so every pump gets a fresh one loaded
    // in real time.
    final packages = (await tester.runAsync(() async {
      final created = (notifier ?? AicovePackagesNotifier.new)(
        Future.value(store),
      );
      await created.ready;
      return created;
    }))!;
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [aicovePackagesProvider.overrideWith((ref) => packages)],
        child: MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: dark ? moeAccentDark : const Color(0xFFFC96AA),
              brightness: dark ? Brightness.dark : Brightness.light,
              surface: dark ? moeSurfaceDark : moeSurface,
              onSurface: dark ? moeTextDark : moeText,
            ),
            scaffoldBackgroundColor: dark ? moeSurfaceDark : moeSurface,
            fontFamily: capture ? 'ExtensionPreview' : null,
            extensions: [dark ? MoeColors.dark() : MoeColors.light()],
          ),
          builder: (context, child) => RepaintBoundary(key: key, child: child!),
          home: const ExtensionPackagesPage(),
        ),
      ),
    );
    await settle(tester);
    return key;
  }

  testWidgets('lists installed packages with skill and script summary', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    await seed(tester);
    for (final dark in [false, true]) {
      final key = await pumpPage(tester, dark: dark);
      expect(find.text('Weekly Report'), findsOneWidget);
      expect(find.text('1 个技能'), findsOneWidget);
      expect(find.text('calculator'), findsOneWidget);
      expect(find.text('脚本'), findsOneWidget);
      expect(find.text('导入 zip'), findsOneWidget);
      expect(find.text('导入文件夹'), findsOneWidget);
      if (capture) {
        await _capture(
          tester,
          key,
          '../../scratch/extension-packages/${dark ? 'dark' : 'light'}-390.png',
        );
      }
    }
  });

  testWidgets('imports a standard skill zip', (tester) async {
    addTearDown(tester.view.reset);
    await seed(tester);
    picker.zipBytes = zip({
      for (final e in skillFiles(name: 'Travel Plan').entries)
        'travel/${e.key}': e.value,
    });
    await pumpPage(tester);
    // The handler does real file I/O and runs QuickJS; start it in real time.
    await tester.runAsync(() async {
      await tester.tap(find.text('导入 zip'));
      await Future.delayed(const Duration(seconds: 2));
    });
    await tester.pump();
    expect(find.text('已导入「Travel Plan」'), findsOneWidget);
    await settle(tester);
    expect(find.text('Travel Plan'), findsOneWidget);
    expect((await tester.runAsync(store.list))!.length, 3);
  });

  testWidgets('long press deletes after confirmation', (tester) async {
    addTearDown(tester.view.reset);
    await seed(tester);
    late _RecordingPackages packages;
    await pumpPage(
      tester,
      notifier: (store) => packages = _RecordingPackages(store),
    );
    await tester.longPress(find.text('calculator'));
    await tester.pumpAndSettle();
    expect(find.text('删除「calculator」后，所有角色都不能再使用它。'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(packages.deleted, ['calculator']);
    expect(find.text('calculator'), findsNothing);
    expect(find.text('Weekly Report'), findsOneWidget);
  });
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String path) async {
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

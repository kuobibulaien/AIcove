import 'dart:io';

import 'package:aicove_flutter/src/features/backup/backup_providers.dart';
import 'package:aicove_flutter/src/features/backup/data/conversation_importer.dart';
import 'package:aicove_flutter/src/features/backup/models/export_format.dart';
import 'package:aicove_flutter/src/ui/features/backup/pages/export_scope_page.dart';
import 'package:aicove_flutter/src/ui/features/backup/pages/import_file_page.dart';
import 'package:aicove_flutter/src/ui/features/backup/pages/import_preview_page.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/release_source_preview.dart';

class _Picker extends FilePicker {
  _Picker(this.path);
  final String path;
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
  }) async =>
      FilePickerResult([PlatformFile(path: path, name: 'b.zip', size: 1)]);
}

class _LockedImporter extends Fake implements ConversationImporter {
  final attempts = <String?>[];
  @override
  Future<ImportPreview> preview(File file, {String? password}) async {
    attempts.add(password);
    if (password == null) {
      throw BackupPasswordRequiredException('该备份已加密，请输入密码');
    }
    if (password != 'p@ss') {
      throw BackupPasswordRequiredException('密码错误，请重新输入');
    }
    return ImportPreview(
        formatVersion: 1,
        appVersion: 'test',
        exportTime: DateTime(2026, 10, 3),
        includedScopes: const [SyncScope.characterCards],
        conversations: const [
          ConversationPreview(id: 'a', displayName: '角色', messageCount: 1)
        ]);
  }
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('aicove-pwd-'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> mount(WidgetTester tester, Widget home, GlobalKey key,
      {List<Override> overrides = const []}) async {
    await loadReleasePreviewFonts(tester);
    await tester.binding.setSurfaceSize(const Size(390, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
        overrides: overrides,
        child: RepaintBoundary(
            key: key,
            child: MaterialApp(
                theme: captureReleaseSourcePreview
                    ? ThemeData(fontFamily: 'ReleasePreview')
                    : null,
                home: home))));
    await tester.pumpAndSettle();
  }

  testWidgets('encrypted backup asks again on wrong password, then opens',
      (tester) async {
    final file = File('${dir.path}/b.zip')..writeAsBytesSync([0]);
    FilePicker.platform = _Picker(file.path);
    final importer = _LockedImporter();
    final key = GlobalKey();
    await mount(tester, const ImportFilePage(), key, overrides: [
      conversationImporterProvider.overrideWithValue(importer),
    ]);

    // 选择文件后的链路在真实异步区运行（读文件），后续交互也留在同一区域推进。
    Future<void> waitFor(Finder finder) => tester.runAsync(() async {
          for (var i = 0; i < 50 && finder.evaluate().isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            await tester.pump(const Duration(milliseconds: 100));
          }
        });
    Future<void> unlock(String password) async {
      await tester.enterText(
          find.byKey(const ValueKey('import-password')).last, password);
      await tester.runAsync(() => tester.tap(find.text('解锁')));
    }

    await tester.runAsync(() => tester.tap(find.text('点击选择文件')));
    await waitFor(find.text('输入备份密码'));
    expect(find.text('输入备份密码'), findsOneWidget);

    await unlock('bad');
    await waitFor(find.text('密码错误，请重新输入'));
    expect(find.text('密码错误，请重新输入'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await saveReleaseSourcePreview(tester, key, 'backup-import-password');

    await unlock('p@ss');
    await waitFor(find.byType(ImportPreviewPage));
    expect(importer.attempts, [null, 'bad', 'p@ss']);
    final page = tester.widget<ImportPreviewPage>(find.byType(ImportPreviewPage));
    expect(page.password, 'p@ss');
    expect(tester.takeException(), isNull);
  });

  testWidgets('export scope page offers an optional password', (tester) async {
    final key = GlobalKey();
    await mount(tester, const ExportScopePage(), key);
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('export-password')), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('留空则不加密'), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('export-password')), '中文ab1');
    expect(find.text('ab1'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await saveReleaseSourcePreview(tester, key, 'backup-export-password');
  });
}

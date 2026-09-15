import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/ui/features/backup/pages/import_file_page.dart';

class DeferredFilePicker extends FilePicker {
  final result = Completer<FilePickerResult?>();
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
  }) =>
      result.future;
}

void main() {
  FilePicker.platform = DeferredFilePicker();
  for (final invalid in [false, true]) {
    testWidgets('import ignores late picker result invalid=$invalid',
        (tester) async {
      final original = FilePicker.platform;
      final picker = DeferredFilePicker();
      FilePicker.platform = picker;
      addTearDown(() => FilePicker.platform = original);
      await tester.pumpWidget(
          const ProviderScope(child: MaterialApp(home: ImportFilePage())));
      await tester.pumpAndSettle();
      await tester.tap(find.text('点击选择文件'));
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      picker.result.complete(invalid
          ? FilePickerResult([
              PlatformFile(
                  name: 'synthetic.txt', size: 0, path: '/synthetic.txt'),
            ])
          : null);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(ImportFilePage), findsNothing);
    });
  }
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/ui/features/settings/pages/log_models.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/log_viewer_page.dart';

UnifiedLogEntry _entry(String title, String fullContent) {
  return UnifiedLogEntry(
    time: DateTime(2026, 3, 19, 9, 0, 0),
    title: title,
    fullContent: fullContent,
  );
}

void main() {
  group('LogViewerExportService', () {
    test('buildExportContent should join entries with separators', () {
      final content =
          LogViewerExportService.buildExportContent(<UnifiedLogEntry>[
        _entry('第一条', '第一条完整内容'),
        _entry('第二条', '第二条完整内容'),
      ]);

      expect(content, contains('第一条完整内容'));
      expect(content, contains('第二条完整内容'));
      expect(RegExp(r'\n---\n').hasMatch(content), isTrue);
      expect(content.endsWith('---'), isFalse);
    });

    test('exportEntries should write bytes after desktop picker returns path',
        () async {
      final entries = <UnifiedLogEntry>[
        _entry('第一条', '第一条完整内容'),
      ];

      String? pickedInitialDirectory;
      Uint8List? writtenBytes;
      String? writtenPath;

      final result = await LogViewerExportService.exportEntries(
        entries: entries,
        now: DateTime(2026, 3, 19, 9, 8, 7),
        initialDirectory: r'C:\Users\developer\Downloads',
        writeBytesInPicker: false,
        saveFile: ({
          String? dialogTitle,
          String? fileName,
          String? initialDirectory,
          FileType type = FileType.any,
          List<String>? allowedExtensions,
          Uint8List? bytes,
          bool lockParentWindow = false,
        }) async {
          pickedInitialDirectory = initialDirectory;
          expect(dialogTitle, '导出日志文件');
          expect(fileName, 'aicove_logs_20260319_090807.txt');
          expect(type, FileType.custom);
          expect(allowedExtensions, const <String>['txt']);
          expect(bytes, isNull);
          expect(lockParentWindow, isTrue);
          return r'C:\Users\developer\Downloads\aicove_logs_20260319_090807.txt';
        },
        writeFileBytes: (path, bytes) async {
          writtenPath = path;
          writtenBytes = bytes;
        },
      );

      expect(pickedInitialDirectory, r'C:\Users\developer\Downloads');
      expect(writtenPath,
          r'C:\Users\developer\Downloads\aicove_logs_20260319_090807.txt');
      expect(utf8.decode(writtenBytes!), contains('第一条完整内容'));
      expect(result, isNotNull);
      expect(result!.savedPath, writtenPath);
      expect(result.fileName, 'aicove_logs_20260319_090807.txt');
      expect(result.entryCount, 1);
    });

    test('exportEntries should pass bytes directly to mobile picker', () async {
      final entries = <UnifiedLogEntry>[
        _entry('第一条', '第一条完整内容'),
        _entry('第二条', '第二条完整内容'),
      ];

      Uint8List? pickerBytes;
      var writerCalled = false;

      final result = await LogViewerExportService.exportEntries(
        entries: entries,
        now: DateTime(2026, 3, 19, 10, 11, 12),
        writeBytesInPicker: true,
        saveFile: ({
          String? dialogTitle,
          String? fileName,
          String? initialDirectory,
          FileType type = FileType.any,
          List<String>? allowedExtensions,
          Uint8List? bytes,
          bool lockParentWindow = false,
        }) async {
          pickerBytes = bytes;
          expect(fileName, 'aicove_logs_20260319_101112.txt');
          expect(initialDirectory, isNull);
          return '/storage/emulated/0/Download/aicove_logs_20260319_101112.txt';
        },
        writeFileBytes: (_, __) async {
          writerCalled = true;
        },
      );

      expect(writerCalled, isFalse);
      expect(pickerBytes, isNotNull);
      expect(utf8.decode(pickerBytes!), contains('第一条完整内容'));
      expect(utf8.decode(pickerBytes!), contains('第二条完整内容'));
      expect(result, isNotNull);
      expect(
        result!.savedPath,
        '/storage/emulated/0/Download/aicove_logs_20260319_101112.txt',
      );
      expect(result.entryCount, 2);
    });
  });
}

import 'dart:io';
import 'dart:typed_data';

import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list_media_save.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class _Picker extends FilePicker {
  String? path;
  @override
  Future<String?> saveFile(
      {String? dialogTitle,
      String? fileName,
      String? initialDirectory,
      FileType type = FileType.any,
      List<String>? allowedExtensions,
      Uint8List? bytes,
      bool lockParentWindow = false}) async {
    expect(allowedExtensions, ['png']);
    expect(fileName, endsWith('.png'));
    return path;
  }
}

void main() {
  testWidgets('桌面保存写入导出字节，取消不覆盖原文件，失败可重试', (tester) async {
    final directory =
        Directory.systemTemp.createTempSync('aicove-export-test-');
    final destination = File('${directory.path}/chat.png');
    final picker = _Picker();
    FilePicker.platform = picker;
    addTearDown(() async {
      directory.deleteSync(recursive: true);
    });
    late BuildContext context;
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(home: Scaffold(body: Builder(builder: (c) {
      context = c;
      return const SizedBox.shrink();
    })))));
    final bytes = Uint8List.fromList([137, 80, 78, 71, 1, 2, 3]);
    await tester.runAsync(() async {
      picker.path = destination.path;
      await saveChatImageBytes(context, bytes);
      expect(await destination.readAsBytes(), bytes);
      picker.path = null;
      await saveChatImageBytes(context, Uint8List.fromList([9]));
      expect(await destination.readAsBytes(), bytes);
      picker.path = '${directory.path}/missing/chat.png';
      await saveChatImageBytes(context, bytes);
      picker.path = destination.path;
      await saveChatImageBytes(context, bytes);
      expect(await destination.readAsBytes(), bytes);
    });
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2200)));
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

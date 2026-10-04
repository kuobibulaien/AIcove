import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/ui/features/chat/pages/chat_interface_settings_page.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';

import 'chat_interface_test_support.dart';

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

Conversation syntheticConversation() => Conversation(
    id: 'audit',
    title: 'Synthetic',
    displayName: 'Synthetic',
    createdAt: DateTime(2026, 9, 6),
    updatedAt: DateTime(2026, 9, 6));

void main() {
  FilePicker.platform = DeferredFilePicker();
  testWidgets('background picker result after page disposal is ignored',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final original = FilePicker.platform;
    final picker = DeferredFilePicker();
    FilePicker.platform = picker;
    addTearDown(() => FilePicker.platform = original);
    await tester.pumpWidget(
      _scope(
        MaterialApp(
          home: ChatInterfaceSettingsPage(
            conversation: syntheticConversation(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('选择背景图片'));
    await tester.pump();
    await tester.pumpWidget(_scope(const MaterialApp(home: Scaffold())));
    picker.result.complete(FilePickerResult([
      PlatformFile(
          name: 'synthetic.png',
          size: 1,
          bytes: base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO7Z0ioAAAAASUVORK5CYII=')),
    ]));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  for (final size in [const Size(320, 568), const Size(1000, 768)]) {
    for (final scale in [1.2, 1.8]) {
      testWidgets('background settings size=$size scale=$scale',
          (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          _scope(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: ChatInterfaceSettingsPage(
                conversation: syntheticConversation(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 450));
        expect(tester.takeException(), isNull);
      });
    }
  }
}

Widget _scope(Widget child) =>
    chatInterfaceTestScope(conversation: syntheticConversation(), child: child);

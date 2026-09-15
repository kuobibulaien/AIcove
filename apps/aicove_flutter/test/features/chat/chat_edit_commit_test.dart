import 'package:drift/native.dart';
import 'dart:async';
import 'dart:io';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/services/attachment_picker_service.dart';
import 'package:aicove_flutter/src/features/chat/chat_actions.dart';
import 'package:aicove_flutter/src/features/chat/chat_layer_providers.dart';
import 'package:aicove_flutter/src/features/chat/application/chat_ports.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/chat/application/chat_edit.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';

class _OfflineSettings extends AppSettingsNotifier {
  final Completer<AppSettings> pending;
  _OfflineSettings(this.pending);
  @override
  Future<AppSettings> build() => pending.future;
}

class _EditSendPort implements ChatSendPort {
  @override
  Message createUserMessage(
          {required String? text, required String? imagePath}) =>
      Message.fromBlocks(
          id: 'new',
          role: 'user',
          createdAt: DateTime.fromMillisecondsSinceEpoch(10),
          blocks: [
            if (text?.isNotEmpty == true)
              TextBlock(messageId: 'new', content: text!),
            if (imagePath != null)
              ImageBlock(messageId: 'new', localPath: imagePath)
          ]);
  @override
  Future<Message> createUserFileMessage(
          {required String filePath, String? text}) async =>
      Message.fromBlocks(
          id: 'new',
          role: 'user',
          createdAt: DateTime.fromMillisecondsSinceEpoch(10),
          blocks: [
            if (text?.isNotEmpty == true)
              TextBlock(messageId: 'new', content: text!),
            FileBlock(
                messageId: 'new',
                fileName: 'file',
                fileSize: 1,
                mimeType: 'text/plain',
                filePath: filePath)
          ]);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('离线测试禁止额外发送或网络请求');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late db.AppDatabase database;
  late ProviderContainer container;
  ChatHistoryStore store() => container.read(chatHistoryStoreProvider);
  Message replacement() => Message(
      id: 'new',
      role: 'user',
      content: '修改后',
      createdAt: DateTime.fromMillisecondsSinceEpoch(10));
  Future<List<String>> ids() async =>
      (await store().loadAllRawMessages('a')).map((m) => m.id).toList();
  setUp(() async {
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    await database.customStatement('PRAGMA foreign_keys = ON');
    container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)]);
    for (final owner in ['a', 'b']) {
      await database.into(database.conversations).insert(
          db.ConversationsCompanion.insert(
              id: owner,
              title: owner,
              displayName: owner,
              createdAt: 0,
              updatedAt: 0));
    }
    for (var i = 0; i < 4; i++) {
      await database.into(database.messages).insert(db.MessagesCompanion.insert(
          id: 'm$i',
          conversationId: 'a',
          role: i.isEven ? 'user' : 'assistant',
          content: '原文$i',
          createdAt: i));
    }
  });
  tearDown(() async {
    container.dispose();
    await database.close();
  });
  for (final kind in ['text', 'image', 'file']) {
    test('真实发送门面 $kind 只等待本地提交，模型准备失败保留新分支', () async {
      final ready = Completer<AppSettings>();
      // 本地受理早于模型准备读取，提前挂载测试错误处理，避免Completer自身无监听报错。
      unawaited(ready.future
          .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
      container.dispose();
      container = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(database),
        activeConversationProvider.overrideWith((ref) => Conversation(
            id: 'a',
            title: 'a',
            displayName: 'a',
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026))),
        appSettingsProvider.overrideWith(() => _OfflineSettings(ready)),
        chatSendPortProvider.overrideWithValue(_EditSendPort()),
      ]);
      final directory =
          await Directory.systemTemp.createTemp('aicove-edit-test-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/$kind');
      await file.writeAsBytes([1]);
      final draft = await store().prepareEdit('a', 'm2');
      final accepted = container.read(chatActionsProvider).submitEditedMessage(
          draft,
          text: kind == 'image' ? '' : '修改后',
          attachment: kind == 'text'
              ? null
              : SelectedAttachment(
                  path: file.path,
                  type: kind == 'image'
                      ? AttachmentType.image
                      : AttachmentType.file));
      await expectLater(
          container
              .read(chatActionsProvider)
              .submitEditedMessage(draft, text: '重复'),
          throwsStateError);
      await accepted.timeout(const Duration(seconds: 5));
      expect(await ids(), ['m0', 'm1', 'new']);
      expect(container.read(conversationSendingProvider('a')), isTrue);
      ready.completeError(StateError('offline model preparation failure'));
      for (var i = 0;
          i < 100 && container.read(conversationSendingProvider('a'));
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(container.read(conversationSendingProvider('a')), isFalse);
      expect(await ids(), ['m0', 'm1', 'new']);
      expect(
          (await container.read(messageRepositoryProvider).getById('new'))!
              .status,
          'failed');
      final restored = (await store().loadAllRawMessages('a')).last;
      if (kind == 'image') {
        expect(restored.blocks!.whereType<ImageBlock>().single.localPath,
            file.path);
      }
      if (kind == 'file') {
        expect(
            restored.blocks!.whereType<FileBlock>().single.filePath, file.path);
      }
    });
  }

  test('准备编辑与恢复标识均不改变原历史', () async {
    final draft = await store().prepareEdit('a', 'm2');
    expect(ChatEditDraft.fromJson(draft.toJson()).historyVersion,
        draft.historyVersion);
    expect(await ids(), ['m0', 'm1', 'm2', 'm3']);
  });
  test('提交仅替换目标及后缀，原记录保留为软删除', () async {
    final draft = await store().prepareEdit('a', 'm2');
    await store().commitEdit(draft, replacement());
    expect(await ids(), ['m0', 'm1', 'new']);
    expect(
        (await container.read(messageRepositoryProvider).getById('m2'))!
            .content,
        '原文2');
    expect(
        (await container.read(messageRepositoryProvider).getById('m2'))!
            .deletedAt,
        isNotNull);
  });
  test('提交写失败回滚旧后缀，重试仍能提交', () async {
    final draft = await store().prepareEdit('a', 'm2');
    await database.customStatement(
        "CREATE TRIGGER fail_edit BEFORE INSERT ON messages WHEN NEW.id = 'new' BEGIN SELECT RAISE(ABORT, 'edit-failure'); END");
    await expectLater(store().commitEdit(draft, replacement()),
        throwsA(predicate((e) => e.toString().contains('edit-failure'))));
    expect(await ids(), ['m0', 'm1', 'm2', 'm3']);
    await database.customStatement('DROP TRIGGER fail_edit');
    await store().commitEdit(draft, replacement());
    expect(await ids(), ['m0', 'm1', 'new']);
  });
  test('编辑附件提交前丢失时不截断历史', () async {
    final draft = await store().prepareEdit('a', 'm2');
    final directory =
        await Directory.systemTemp.createTemp('aicove-edit-missing-');
    addTearDown(() => directory.delete(recursive: true));
    final message = Message.fromBlocks(id: 'new', role: 'user', blocks: [
      ImageBlock(messageId: 'new', localPath: '${directory.path}/missing.png')
    ]);
    await expectLater(store().commitEdit(draft, message), throwsStateError);
    expect(await ids(), ['m0', 'm1', 'm2', 'm3']);
  });

  test('历史追加后拒绝过期草稿，不截掉新消息', () async {
    final draft = await store().prepareEdit('a', 'm2');
    await database.into(database.messages).insert(db.MessagesCompanion.insert(
        id: 'later',
        conversationId: 'a',
        role: 'assistant',
        content: '新到达',
        createdAt: 9));
    await expectLater(
        store().commitEdit(draft, replacement()), throwsStateError);
    expect(await ids(), ['m0', 'm1', 'm2', 'm3', 'later']);
  });
  test('错误owner与助手消息都不能准备编辑', () async {
    await expectLater(store().prepareEdit('b', 'm2'), throwsStateError);
    await expectLater(store().prepareEdit('a', 'm3'), throwsStateError);
  });
  test('同一编辑重复提交不能生成第二个分支', () async {
    final draft = await store().prepareEdit('a', 'm2');
    await store().commitEdit(draft, replacement());
    await expectLater(
        store().commitEdit(draft, replacement()), throwsStateError);
    expect(await ids(), ['m0', 'm1', 'new']);
  });
  test('话题边界内编辑不删除边界，旧话题编辑拒绝', () async {
    await database.customStatement(
        "UPDATE conversations SET context_start_message_id = 'm1' WHERE id = 'a'");
    await expectLater(store().prepareEdit('a', 'm0'), throwsStateError);
    final draft = await store().prepareEdit('a', 'm2');
    await store().commitEdit(draft, replacement());
    expect((await store().loadCanonicalContextMessages('a')).map((m) => m.id),
        ['new']);
  });
}

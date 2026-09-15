import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/chat/chat_actions.dart';
import 'package:aicove_flutter/src/features/chat/chat_layer_providers.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/conversation_timeline_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/chat/pages/chat_page.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import '../../../../features/chat/edit_regenerate_audit_test.dart'
    show AuditHistory, AuditSettings, auditSettings;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final width in [360.0, 1000.0]) {
    for (final enhanced in [false, true]) {
      testWidgets('真实ChatPage重生成忙碌与失败解锁 width=$width enhanced=$enhanced',
          (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final time = DateTime(2026, 9, 6);
        final user =
            Message(id: 'ui-u', role: 'user', content: '测试问题', createdAt: time);
        final ai = Message(
            id: 'ui-a',
            role: 'assistant',
            content: '测试旧回复',
            createdAt: time.add(const Duration(seconds: 1)));
        final conv = Conversation(
            id: 'ui',
            title: '测试',
            displayName: '测试',
            createdAt: time,
            updatedAt: time);
        final database = db.AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        await database.into(database.conversations).insert(
            db.ConversationsCompanion.insert(
                id: conv.id,
                title: conv.title,
                displayName: conv.displayName,
                createdAt: 0,
                updatedAt: 0));
        for (final m in [user, ai]) {
          await database.into(database.messages).insert(
              db.MessagesCompanion.insert(
                  id: m.id,
                  conversationId: conv.id,
                  role: m.role,
                  content: m.content,
                  createdAt: m.createdAt.millisecondsSinceEpoch));
        }
        final history = AuditHistory([user, ai])
          ..pendingRead = Completer<List<Message>>();
        final container = ProviderContainer(overrides: [
          databaseProvider.overrideWithValue(database),
          appSettingsProvider
              .overrideWith(() => AuditSettings(Future.value(auditSettings))),
          chatHistoryPortProvider.overrideWithValue(history),
          activeConversationProvider.overrideWith((ref) => conv),
          resolvedConversationByIdProvider(conv.id).overrideWith((ref) => conv),
          conversationMessagesProvider(conv.id)
              .overrideWith((ref) => AsyncData([user, ai])),
          conversationHasMoreProvider(conv.id).overrideWith((ref) => false),
        ]);
        addTearDown(container.dispose);
        await tester.pumpWidget(UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: ThemeData(extensions: [MoeColors.light()]),
              home:
                  ChatPage(conversationId: conv.id, initialConversation: conv),
            )));
        await tester.pumpAndSettle();
        final list =
            tester.widget<ChatMessageList>(find.byType(ChatMessageList));
        final action = enhanced
            ? list.onEnhanceRegenerateMessage!
            : list.onRegenerateMessage!;
        // 业务链含插件/SQLite异步：在真实时钟中启动，避免跨fakeAsync等待。
        await tester.runAsync(() async {
          action(ai);
          action(ai);
          for (var i = 0; i < 100 && history.reads == 0; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        await tester.pump();
        final busyDuringRead =
            container.read(conversationSendingProvider(conv.id));
        final statusDuringRead = container.read(chatStatusProvider);
        final readsDuringWait = history.reads;
        history.pendingRead!.complete([user, ai]);
        // 同时推进Flutter的模拟时钟与真实IO，不能在runAsync里等待fakeAsync创建的Completer。
        for (var i = 0;
            i < 100 && container.read(conversationSendingProvider(conv.id));
            i++) {
          await tester.pump(const Duration(milliseconds: 10));
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
        }
        await tester.pumpAndSettle();
        expect(busyDuringRead, isTrue);
        expect(statusDuringRead, ChatStatus.thinking);
        expect(readsDuringWait, 1, reason: '真实页面第二次点击不应再次读取历史');
        expect(tester.takeException(), isNull);
        expect(history.truncations, 1);
        expect(container.read(conversationSendingProvider(conv.id)), isFalse);
        expect(
            container.read(errorProvider), contains('audit truncate failure'));
        expect(find.text('测试旧回复'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}

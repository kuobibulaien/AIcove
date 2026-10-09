import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/chat/application/privacy_space.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/contacts_list_content.dart';
import 'package:aicove_flutter/src/ui/features/home/pages/privacy_space_page.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

class _MemoryStore {
  String? value;

  PrivacySpaceStore get store => PrivacySpaceStore(
    read: () async => value,
    write: (next) async => value = next,
  );
}

class _FakeConversationsNotifier extends ConversationsNotifier {
  _FakeConversationsNotifier(this._conversations);

  final List<Conversation> _conversations;

  @override
  Future<List<Conversation>> build() async => _conversations;

  @override
  Future<void> setAll(List<Conversation> list, {bool persist = true}) async {
    state = AsyncData(list);
  }
}

Conversation _conversation(String id, String name, {bool hidden = false}) {
  final now = DateTime(2026, 10, 9);
  return Conversation(
    id: id,
    title: name,
    displayName: name,
    createdAt: now,
    updatedAt: now,
    isHidden: hidden,
  );
}

void main() {
  test('密码只存带盐哈希的单个字符串，验证读最新存储', () async {
    final memory = _MemoryStore();
    final password = PrivacySpacePassword(memory.store);

    expect(await password.isSet(), isFalse);
    await password.set('2468');

    expect(memory.value, startsWith(r'v1$'));
    expect(memory.value, isNot(contains('2468')));
    expect(await password.isSet(), isTrue);
    expect(await password.verify('2468'), isTrue);
    expect(await password.verify('1357'), isFalse);

    // 模拟另一台设备改密后同步过来。
    final other = _MemoryStore();
    await PrivacySpacePassword(other.store).set('9999');
    memory.value = other.value;
    expect(await password.verify('2468'), isFalse);
    expect(await password.verify('9999'), isTrue);
  });

  testWidgets('隐藏联系人不出现在列表，下拉半屏输入密码后进入隐私空间', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final memory = _MemoryStore();
    final container = ProviderContainer(
      overrides: [
        privacySpaceStoreProvider.overrideWithValue(memory.store),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([
            _conversation('open', '公开联系人'),
            _conversation('secret', '秘密联系人', hidden: true),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.runAsync(
      () => container.read(privacySpacePasswordProvider).set('2468'),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(extensions: [MoeColors.light()]),
          home: const Scaffold(body: ContactsListContent()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('公开联系人'), findsOneWidget);
    expect(find.text('秘密联系人'), findsNothing);

    // 不到半屏不触发。
    await tester.dragFrom(const Offset(200, 100), const Offset(0, 250));
    await tester.pumpAndSettle();
    expect(find.text('进入隐私空间'), findsNothing);

    final gesture = await tester.startGesture(const Offset(200, 100));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, 45));
      await tester.pump();
    }
    expect(find.text('松开进入隐私空间'), findsOneWidget);
    await gesture.up();
    // 隐私状态在真实 zone 中加载，等它的回调落地再推进帧。
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.text('进入隐私空间'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('privacy-password-field')),
      '2468',
    );
    await tester.tap(find.text('确定'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PrivacySpacePage), findsOneWidget);
    expect(find.text('秘密联系人'), findsOneWidget);
  });

  testWidgets('首次隐藏联系人会先引导设置密码', (tester) async {
    final memory = _MemoryStore();
    final container = ProviderContainer(
      overrides: [
        privacySpaceStoreProvider.overrideWithValue(memory.store),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([_conversation('c1', '小纸条')]),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(extensions: [MoeColors.light()]),
          home: const Scaffold(body: ContactsListContent()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.text('小纸条'), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.text('置顶'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    await tester.tap(find.text('隐藏'));
    await tester.pumpAndSettle();

    expect(find.text('设置隐私空间密码'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('privacy-password-field')),
      '8888',
    );
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('privacy-password-field')),
      '8888',
    );
    await tester.tap(find.text('确定'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();

    expect(memory.value, isNotNull);
    expect(
      container.read(conversationsProvider).requireValue.single.isHidden,
      isTrue,
    );
    expect(find.text('小纸条'), findsNothing);
    await tester.pump(const Duration(seconds: 3));
  });
}

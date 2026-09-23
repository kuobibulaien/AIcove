import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/memory/application/memory_keeper_service.dart';
import 'package:aicove_flutter/src/features/memory/domain/memory_item.dart';
import 'package:aicove_flutter/src/features/memory/domain/memory_ports.dart';
import 'package:aicove_flutter/src/features/memory/providers/memory_providers.dart';
import 'package:aicove_flutter/src/ui/features/character/pages/contact_memory_page.dart';

/// 纯内存的记忆存储，只实现页面会用到的行为。
class _Store implements MemoryStorePort {
  final items = <MemoryItem>[];
  var _next = 0;
  @override
  Future<List<MemoryItem>> list(String ownerId, {MemoryLayer? layer}) async =>
      items
          .where((i) => i.ownerId == ownerId && (layer == null || i.layer == layer))
          .toList();
  @override
  Future<MemoryItem?> get(String ownerId, String id) async =>
      items.where((i) => i.ownerId == ownerId && i.id == id).firstOrNull;
  @override
  Future<MemoryItem> saveByUser({
    required String ownerId,
    String? id,
    required MemoryLayer layer,
    required String title,
    required String content,
  }) async {
    if (title.trim().isEmpty) throw const MemoryException('记忆标题须为 1–120 字的单行文字。');
    items.removeWhere((i) => i.id == id);
    final item = MemoryItem(
      id: id ?? 'i${_next++}',
      ownerId: ownerId,
      layer: layer,
      title: title.trim(),
      content: content.trim(),
      sourceIds: const [],
      locked: true,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    items.add(item);
    return item;
  }

  @override
  Future<void> setLocked(String ownerId, String id, bool locked) async {
    final index = items.indexWhere((i) => i.id == id);
    items[index] = items[index].copyWith(locked: locked);
  }

  @override
  Future<void> deleteByUser(String ownerId, String id) async =>
      items.removeWhere((i) => i.ownerId == ownerId && i.id == id);
  @override
  Future<MemoryProgress> progress(String ownerId) async =>
      MemoryProgress(ownerId: ownerId);
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MemoryItem _item(String owner, String id, MemoryLayer layer, {bool locked = false}) =>
    MemoryItem(
      id: id,
      ownerId: owner,
      layer: layer,
      title: '$owner-$id',
      content: '$owner 的 $id',
      sourceIds: const [],
      locked: locked,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

Widget _app(_Store store, Widget home, {bool allowed = true}) => ProviderScope(
  overrides: [
    memoryStoreProvider.overrideWithValue(store),
    memoryKeeperProvider.overrideWith(
      (ref) => MemoryKeeperService(
        store: store,
        loadMessages: (_) async => const <Message>[],
        compactedBoundaries: (_) async => const {},
        agentFactory: () => throw StateError('no agent in widget test'),
        allowed: (_) async => allowed,
      ),
    ),
  ],
  child: MaterialApp(home: home),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final width in [360.0, 1000.0]) {
    testWidgets('$width 宽：分常驻与档案展示，新增的记忆自动锁定且只写指定角色', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = _Store()
        ..items.addAll([
          _item('a', 'c1', MemoryLayer.core),
          _item('a', 'r1', MemoryLayer.archive),
          _item('b', 'r2', MemoryLayer.archive),
        ]);
      await tester.pumpWidget(
        _app(store, const ContactMemoryPage(ownerId: 'a', displayName: '角色A')),
      );
      await tester.pumpAndSettle();
      expect(find.text('角色A的记忆'), findsOneWidget);
      expect(find.text('a-c1'), findsOneWidget);
      expect(find.text('a-r1'), findsOneWidget);
      expect(find.text('b-r2'), findsNothing);
      expect(find.textContaining('已是最新'), findsOneWidget);

      await tester.ensureVisible(find.text('添加档案记忆'));
      await tester.tap(find.text('添加档案记忆'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '雨中散步');
      await tester.enterText(find.byType(TextField).at(1), '一起撑着紫色雨伞散步');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('雨中散步'), findsOneWidget);
      final saved = store.items.singleWhere((i) => i.title == '雨中散步');
      expect(saved.ownerId, 'a');
      expect(saved.layer, MemoryLayer.archive);
      expect(saved.locked, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('删除需确认；锁定切换写回存储', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = _Store()..items.add(_item('a', 'r1', MemoryLayer.archive));
    await tester.pumpWidget(
      _app(store, const ContactMemoryPage(ownerId: 'a', displayName: 'A')),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byIcon(Icons.lock_open_outlined));
    await tester.tap(find.byIcon(Icons.lock_open_outlined));
    await tester.pumpAndSettle();
    expect(store.items.single.locked, isTrue);
    await tester.ensureVisible(find.byIcon(Icons.delete_outline));
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('删除这条记忆？'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(store.items, isEmpty);
  });

  testWidgets('页面复用到另一角色时，不显示上一角色的记忆', (tester) async {
    final store = _Store()
      ..items.addAll([
        _item('a', 'r1', MemoryLayer.archive),
        _item('b', 'r2', MemoryLayer.archive),
      ]);
    final owner = ValueNotifier('a');
    addTearDown(owner.dispose);
    await tester.pumpWidget(
      _app(
        store,
        ValueListenableBuilder<String>(
          valueListenable: owner,
          builder: (_, id, __) => ContactMemoryPage(ownerId: id, displayName: id),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('a-r1'), findsOneWidget);
    owner.value = 'b';
    await tester.pumpAndSettle();
    expect(find.text('a-r1'), findsNothing);
    expect(find.text('b-r2'), findsOneWidget);
  });

  testWidgets('角色未启用记忆库时明确提示，重建不可用', (tester) async {
    await tester.pumpWidget(
      _app(
        _Store(),
        const ContactMemoryPage(ownerId: 'a', displayName: 'A'),
        allowed: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('未在插件列表里启用'), findsOneWidget);
  });
}

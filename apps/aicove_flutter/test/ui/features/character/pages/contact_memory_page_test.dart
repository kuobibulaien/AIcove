import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/features/memory/domain/contact_memory_port.dart';
import 'package:aicove_flutter/src/features/memory/providers/contact_memory_provider.dart';
import 'package:aicove_flutter/src/ui/features/character/pages/contact_memory_page.dart';

class _Port implements ContactMemoryPort {
  final saved = <String, ContactMemoryNotebook>{};
  bool failSave = false;
  @override
  Future<ContactMemoryNotebook> load(String ownerId) async =>
      saved[ownerId] ?? ContactMemoryNotebook(ownerId: ownerId);
  @override
  Future<ContactMemoryNotebook> save(ContactMemoryNotebook notebook) async {
    if (failSave) throw const ContactMemoryConflict();
    saved[notebook.ownerId] = notebook.copyWith(revision: 'saved');
    return saved[notebook.ownerId]!;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final width in [360.0, 1000.0]) {
    testWidgets('$width 宽：编辑常驻记忆、添加往事、切换模式并保存到指定角色', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final port = _Port();
      await tester.pumpWidget(ProviderScope(
          overrides: [contactMemoryPortProvider.overrideWithValue(port)],
          child: const MaterialApp(
              home: ContactMemoryPage(ownerId: 'a', displayName: '角色A'))));
      await tester.pumpAndSettle();
      expect(find.text('角色A的记忆'), findsOneWidget);
      await tester.tap(find.text('使用独立 MD 记忆'));
      await tester.tap(find.text('编辑常驻笔记'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '先倾听，不要马上给建议');
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('添加往事'));
      await tester.tap(find.text('添加往事'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '雨中散步');
      await tester.enterText(find.byType(TextField).at(2), '一起撑着紫色雨伞散步');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('雨中散步'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(port.saved['a']!.enabled, isTrue);
      expect(port.saved['a']!.core, '先倾听，不要马上给建议');
      expect(port.saved['a']!.events.single.body, '一起撑着紫色雨伞散步');
      expect(port.saved.containsKey('b'), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('页面复用到另一角色时，不显示或保存上一角色的草稿', (tester) async {
    final port = _Port();
    port.saved['a'] = ContactMemoryNotebook(ownerId: 'a', core: 'A的秘密');
    port.saved['b'] = ContactMemoryNotebook(ownerId: 'b', core: 'B的记忆');
    final owner = ValueNotifier('a');
    addTearDown(owner.dispose);
    await tester.pumpWidget(ProviderScope(
        overrides: [contactMemoryPortProvider.overrideWithValue(port)],
        child: MaterialApp(
            home: ValueListenableBuilder<String>(
          valueListenable: owner,
          builder: (_, id, __) =>
              ContactMemoryPage(ownerId: id, displayName: id),
        ))));
    await tester.pumpAndSettle();
    expect(find.text('A的秘密'), findsOneWidget);
    owner.value = 'b';
    await tester.pumpAndSettle();
    expect(find.text('A的秘密'), findsNothing);
    expect(find.text('B的记忆'), findsOneWidget);
  });

  testWidgets('保存冲突不丢页面草稿，能重试保存', (tester) async {
    final port = _Port()..failSave = true;
    await tester.pumpWidget(ProviderScope(
        overrides: [contactMemoryPortProvider.overrideWithValue(port)],
        child: const MaterialApp(
            home: ContactMemoryPage(ownerId: 'a', displayName: 'A'))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用独立 MD 记忆'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.textContaining('自动保存失败'), findsOneWidget);
    expect(port.saved, isEmpty);
    port.failSave = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(port.saved['a']!.enabled, isTrue);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('冲突后可明确重新加载最新记忆，普通编辑不弹确认', (tester) async {
    final port = _Port()..failSave = true;
    await tester.pumpWidget(ProviderScope(
      overrides: [contactMemoryPortProvider.overrideWithValue(port)],
      child: const MaterialApp(
          home: ContactMemoryPage(ownerId: 'a', displayName: 'A')),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用独立 MD 记忆'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    port.saved['a'] = ContactMemoryNotebook(ownerId: 'a', core: '其他操作更新的记忆');
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    expect(find.text('重新加载最新记忆？'), findsOneWidget);
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();
    expect(find.text('其他操作更新的记忆'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
  });
}

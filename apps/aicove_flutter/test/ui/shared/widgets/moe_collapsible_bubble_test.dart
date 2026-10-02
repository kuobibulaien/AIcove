import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_collapsible_bubble.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const previewDir = String.fromEnvironment('COLLAPSIBLE_PREVIEW_DIR');

const _title = '状态栏 · 第 3 天 傍晚';
const _content = '地点：图书馆三楼靠窗的位置\n心情：有点累，但看到你来了就好多了\n好感度：72 → 75';

Widget _app({required Widget child, bool dark = false, double textScale = 1}) {
  final colors = dark ? MoeColors.dark() : MoeColors.light();
  return ProviderScope(
    child: RepaintBoundary(
      key: const ValueKey('capture'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: dark ? Brightness.dark : Brightness.light,
          fontFamily: previewDir.isEmpty ? null : 'CollapsiblePreview',
          extensions: [colors],
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(backgroundColor: colors.bgMain, body: child),
      ),
    ),
  );
}

/// 与 MessageBubble 的头像列对齐（外边距 8 + 头像 42 + 间隔 8）。
Widget _aligned({required bool isMe, required Widget child}) => Align(
  alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
  child: Padding(
    padding: EdgeInsets.only(left: isMe ? 60 : 58, right: isMe ? 8 : 60),
    child: child,
  ),
);

double _plainBubbleHeight(WidgetTester tester) => tester
    .getSize(
      find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('message_bubble_'),
      ),
    )
    .height;

Future<void> _capture(WidgetTester tester, String name) async {
  if (previewDir.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(
      '$previewDir/$name.png',
    ).writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    if (previewDir.isEmpty) return;
    for (final entry in {
      'CollapsiblePreview': '/System/Library/Fonts/STHeiti Medium.ttc',
      'MaterialIcons':
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final loader = FontLoader(entry.key);
      loader.addFont(
        File(entry.value).readAsBytes().then(ByteData.sublistView),
      );
      await loader.load();
    }
  });

  testWidgets('默认折叠只显示标题，点击气泡展开并回调，再点收起', (tester) async {
    final changes = <bool>[];
    await tester.pumpWidget(
      _app(
        child: _aligned(
          isMe: false,
          child: MoeCollapsibleBubble(
            isMe: false,
            title: _title,
            content: _content,
            onExpansionChanged: changes.add,
          ),
        ),
      ),
    );
    expect(find.text(_title), findsOneWidget);
    expect(find.text(_content), findsNothing);

    await tester.tap(find.text(_title));
    await tester.pumpAndSettle();
    expect(find.text(_content), findsOneWidget);

    await tester.tap(find.text(_content));
    await tester.pumpAndSettle();
    expect(find.text(_content), findsNothing);
    expect(changes, [true, false]);
  });

  testWidgets('标题栏只占一行，超长标题省略', (tester) async {
    const longTitle = '这是一段非常非常长的标题，用来确认折叠气泡的标题栏始终只占一行不会换行';
    await tester.pumpWidget(
      _app(
        child: _aligned(
          isMe: false,
          child: const MoeCollapsibleBubble(
            isMe: false,
            title: longTitle,
            content: _content,
          ),
        ),
      ),
    );
    final title = tester.widget<Text>(find.text(longTitle));
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
  });

  testWidgets('可选 child 展开后代替纯文本正文', (tester) async {
    await tester.pumpWidget(
      _app(
        child: const MoeCollapsibleBubble(
          isMe: true,
          title: _title,
          content: _content,
          child: Text('自定义正文'),
        ),
      ),
    );
    expect(find.text('自定义正文'), findsNothing);
    await tester.tap(find.text(_title));
    await tester.pumpAndSettle();
    expect(find.text('自定义正文'), findsOneWidget);
    expect(find.text(_content), findsNothing);
  });

  for (final (fontSize, textScale) in [(15.0, 1.0), (15.0, 1.4), (18.0, 0.9)]) {
    testWidgets('折叠高度等于单行消息气泡 字号$fontSize 缩放$textScale', (tester) async {
      await tester.pumpWidget(
        _app(
          textScale: textScale,
          child: Column(
            children: [
              MessageBubble.text(isMe: false, text: '单行', fontSize: fontSize),
              _aligned(
                isMe: false,
                child: MoeCollapsibleBubble(
                  key: const ValueKey('collapsible'),
                  isMe: false,
                  title: _title,
                  content: _content,
                  leadingIcon: Icons.notes_rounded,
                  fontSize: fontSize,
                ),
              ),
            ],
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(const ValueKey('collapsible'))).height,
        moreOrLessEquals(_plainBubbleHeight(tester), epsilon: 0.01),
      );
    });
  }

  for (final dark in [false, true]) {
    for (final (width, textScale) in [
      (390.0, 1.0),
      (390.0, 1.3),
      (1000.0, 1.0),
    ]) {
      testWidgets('预览无溢出 ${dark ? '深' : '浅'} $width 缩放$textScale', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 560);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          _app(
            dark: dark,
            textScale: textScale,
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 16),
              children: [
                MessageBubble.text(isMe: true, text: '今天在图书馆等你好久啦'),
                const SizedBox(height: 10),
                MessageBubble.text(isMe: false, text: '抱歉抱歉，路上耽误了一会儿～'),
                const SizedBox(height: 10),
                _aligned(
                  isMe: false,
                  child: const MoeCollapsibleBubble(
                    isMe: false,
                    title: _title,
                    content: _content,
                  ),
                ),
                const SizedBox(height: 10),
                _aligned(
                  isMe: false,
                  child: const MoeCollapsibleBubble(
                    isMe: false,
                    title: _title,
                    content: _content,
                    initiallyExpanded: true,
                  ),
                ),
                const SizedBox(height: 10),
                _aligned(
                  isMe: true,
                  child: const MoeCollapsibleBubble(
                    isMe: true,
                    title: '我的备注',
                    content: '记得提醒她明天带伞。',
                    leadingIcon: Icons.bookmark_outline_rounded,
                  ),
                ),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await _capture(
          tester,
          'bubble-${dark ? 'dark' : 'light'}-${width.toInt()}'
          '-x${textScale.toStringAsFixed(1)}',
        );
      });
    }
  }
}

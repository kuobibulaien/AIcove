import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 功能页里手写 `color: colors.surface` / `colors.componentBackground` 的底色，
/// 在模糊、玻璃档下仍是实心白块（见公共组件总览「高级材质接入排查」）。
/// 独立卡片用 `MoeContentSurface`（长列表用 `MoeSliverContentSurface`），
/// 卡片或画框里的徽标、文本槽、图片位用 `MoeInsetSurface`，浮动控件用
/// `MoeFloatingSurface`，页面底色交给 `MoePageScaffold` / `MoeGlobalWallpaper`。
final _handPaintedSurface = RegExp(
  r'color:\s*colors\.(surface|componentBackground)\b\s*[,)]',
);

void main() {
  test('features do not hand-paint solid surface fills', () {
    const root = 'lib/src/ui/features/';
    final hits = <String>[];
    for (final entity in Directory(root).listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (_handPaintedSurface.hasMatch(lines[i])) {
          hits.add('${entity.path.substring(root.length)}:${i + 1}');
        }
      }
    }
    expect(hits, isEmpty, reason: '手写实色底，请改用公共材质组件：\n${hits.join('\n')}');
  });
}

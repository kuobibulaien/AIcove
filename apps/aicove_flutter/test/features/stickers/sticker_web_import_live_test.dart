import 'dart:io';

import 'package:aicove_flutter/src/features/stickers/sticker_library.dart';
import 'package:aicove_flutter/src/features/stickers/sticker_web_import.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实网络测试：设置 AICOVE_LIVE_WECHAT=1 才会访问公众号文章，平时跳过。
void main() {
  const url = 'https://mp.weixin.qq.com/s/n_M3RocL52yWXb_iYAPOwA';
  final live = Platform.environment['AICOVE_LIVE_WECHAT'] == '1';

  test(
    '真实公众号文章：抓到的表情都达到最短边，封面不计入',
    () async {
      final page = await fetchStickerPage(Uri.parse(url));
      // ignore: avoid_print
      print(
        'title=${page.title} found=${page.foundCount} '
        'images=${page.images.length} small=${page.smallCount} '
        'failed=${page.failedCount}',
      );
      expect(page.title, '咪不服');
      expect(page.images.length, greaterThanOrEqualTo(12));
      expect(page.failedCount, 0);
      for (final image in page.images) {
        expect(
          image.name,
          matches(RegExp(r'^image-\d{2}\.(jpg|png|gif|webp)$')),
        );
        expect(image.bytes.length, lessThan(StickerLibrary.maxFileBytes));
      }
    },
    skip: live ? false : '设置 AICOVE_LIVE_WECHAT=1 才访问真实网络',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

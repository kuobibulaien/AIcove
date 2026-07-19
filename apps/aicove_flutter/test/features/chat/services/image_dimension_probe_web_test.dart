@TestOn('browser')
library;

// Web 硬门运行态测试（chrome 平台）：
//
// 1. 证明门面在 Web 条件导入下解析为 probe_stub（恒返回 null）：
//    若解析到 probe_io（dart:io / Isolate.run 路径），本文件在 dart2js 下
//    根本无法编译通过——编译成功＋运行通过即证明「无 Isolate.run 路径」。
// 2. 证明对合法可解码图片同样返回 null（若是原生实现则会返回 1×1）。
// 3. 证明反复调用恒定返回 null 且不抛异常（探测层静默收敛前提）。
//
// 注意：店（ConversationTimelineCache）级别的「一次 attempted 后静默收敛」
// 无法在 chrome 上直接验证——store 传递依赖 database.dart →
// package:drift/native.dart（dart:ffi），非 browser-safe。该收敛语义为平台
// 无关的纯 Dart 逻辑，已在 VM 侧 conversation_short_window_store_test.dart
// 中以真实 probe_stub 注入完成同语义验证（见「Web 桩注入」用例）。
//
// 本文件不得 import package:drift/native.dart 等 VM-only 依赖。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import 'package:aicove_flutter/src/features/chat/services/image_dimension_probe/image_dimension_probe.dart';

void main() {
  test('Web 门面对合法 PNG base64 返回 null（桩解析证明）', () async {
    final pngBytes = img.encodePng(img.Image(width: 1, height: 1));
    final payload = base64Encode(pngBytes);

    final result = await probeImageDimensions(
      ImageDimensionProbeInput(base64: payload),
    );

    expect(result, isNull, reason: '原生实现会返回 1×1；Web 必须解析为恒 null 的桩。');
  });

  test('Web 门面对 localPath / file:// 输入返回 null 且不抛异常', () async {
    final byPath = await probeImageDimensions(
      const ImageDimensionProbeInput(localPath: '/tmp/whatever.png'),
    );
    final byFileUrl = await probeImageDimensions(
      const ImageDimensionProbeInput(fileUrl: 'file:///tmp/whatever.png'),
    );

    expect(byPath, isNull);
    expect(byFileUrl, isNull);
  });

  test('反复调用恒定返回 null（探测层静默收敛前提）', () async {
    final pngBytes = img.encodePng(img.Image(width: 2, height: 2));
    final input = ImageDimensionProbeInput(base64: base64Encode(pngBytes));

    for (var i = 0; i < 3; i += 1) {
      expect(await probeImageDimensions(input), isNull);
    }
  });

  test('imageDimensionProbeProvider 注入的也是恒 null 桩', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final probe = container.read(imageDimensionProbeProvider);
    final pngBytes = img.encodePng(img.Image(width: 1, height: 1));

    expect(
      await probe(ImageDimensionProbeInput(base64: base64Encode(pngBytes))),
      isNull,
    );
  });
}

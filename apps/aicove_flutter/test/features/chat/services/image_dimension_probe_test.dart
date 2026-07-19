import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:aicove_flutter/src/features/chat/services/image_dimension_probe/probe_io.dart'
    as probe_io;
import 'package:aicove_flutter/src/features/chat/services/image_dimension_probe/probe_stub.dart'
    as probe_stub;
import 'package:aicove_flutter/src/features/chat/services/image_dimension_probe/probe_types.dart';

Future<File> _writePng(
  String filePath, {
  required int width,
  required int height,
}) async {
  final image = img.Image(width: width, height: height);
  final bytes = img.encodePng(image);
  final file = File(filePath);
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('image_dim_probe_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('localPath 来源：PNG 头信息路径返回尺寸并标记命中来源', () async {
    final file = await _writePng('${tempDir.path}/a.png', width: 64, height: 48);

    final result = await probe_io.probeImageDimensions(
      ImageDimensionProbeInput(localPath: file.path),
    );

    expect(result, isNotNull);
    expect(result!.width, 64);
    expect(result.height, 48);
    expect(result.hitSource, ImageDimensionProbeSource.localPath);
  });

  test('file:// URL 来源可解析', () async {
    final file = await _writePng('${tempDir.path}/b.png', width: 8, height: 6);

    final result = await probe_io.probeImageDimensions(
      ImageDimensionProbeInput(fileUrl: Uri.file(file.path).toString()),
    );

    expect(result, isNotNull);
    expect(result!.width, 8);
    expect(result.height, 6);
    expect(result.hitSource, ImageDimensionProbeSource.fileUrl);
  });

  test('base64 来源：裸 base64 与 data URL 都可解析', () async {
    final bytes = img.encodePng(img.Image(width: 3, height: 5));
    final rawBase64 = base64Encode(bytes);

    final rawResult = await probe_io.probeImageDimensions(
      ImageDimensionProbeInput(base64: rawBase64),
    );
    expect(rawResult, isNotNull);
    expect(rawResult!.width, 3);
    expect(rawResult.height, 5);
    expect(rawResult.hitSource, ImageDimensionProbeSource.base64);

    final dataUrlResult = await probe_io.probeImageDimensions(
      ImageDimensionProbeInput(base64: 'data:image/png;base64,$rawBase64'),
    );
    expect(dataUrlResult, isNotNull);
    expect(dataUrlResult!.width, 3);
    expect(dataUrlResult.height, 5);
  });

  test('损坏图片返回 null 而不抛异常', () async {
    final file = File('${tempDir.path}/broken.png');
    await file.writeAsBytes(
      List<int>.generate(256, (index) => index % 251),
      flush: true,
    );

    final result = await probe_io.probeImageDimensions(
      ImageDimensionProbeInput(localPath: file.path),
    );

    expect(result, isNull);
  });

  test('文件缺失返回 null', () async {
    final result = await probe_io.probeImageDimensions(
      ImageDimensionProbeInput(localPath: '${tempDir.path}/missing.png'),
    );

    expect(result, isNull);
  });

  test('File.length 超限预检：byteLimit 注入小值时有效文件也返回 null', () async {
    final file =
        await _writePng('${tempDir.path}/big.png', width: 32, height: 32);
    expect(await file.length(), greaterThan(10));

    final result = await probe_io.probeImageDimensions(
      ImageDimensionProbeInput(localPath: file.path, byteLimit: 10),
    );

    expect(result, isNull);
  });

  test('base64 解码尺寸估算预检：超限返回 null', () async {
    final bytes = img.encodePng(img.Image(width: 32, height: 32));
    final payload = base64Encode(bytes);
    // 估算值 (len * 3) ~/ 4 ≥ 实际解码尺寸；上限设 10 必然超限。
    //
    // 覆盖声明（如实）：本用例只命中「估算预检」分支。probe_io 中的
    // 「解码后二次校验」与「整图解码回退」两个分支为防御性保留——
    // 对合法带 padding 的 base64，估算恒 ≥ 实际，二次校验数学上不可达；
    // decodeImage 与 findDecoderForData 共用解码器选择，常规输入无法
    // 构造「头解析失败但整图成功」。两分支未被测试触达，仅为兜底。
    final result = await probe_io.probeImageDimensions(
      ImageDimensionProbeInput(base64: payload, byteLimit: 10),
    );

    expect(result, isNull);
  });

  test('多来源回退：localPath 失效时回退 base64 并标记命中来源', () async {
    final bytes = img.encodePng(img.Image(width: 11, height: 7));

    final result = await probe_io.probeImageDimensions(
      ImageDimensionProbeInput(
        localPath: '${tempDir.path}/not_exists.png',
        base64: base64Encode(bytes),
      ),
    );

    expect(result, isNotNull);
    expect(result!.width, 11);
    expect(result.height, 7);
    expect(result.hitSource, ImageDimensionProbeSource.base64);
  });

  test('非法 base64 返回 null 而不抛异常', () async {
    final result = await probe_io.probeImageDimensions(
      const ImageDimensionProbeInput(base64: 'not-valid-base64!!!'),
    );

    expect(result, isNull);
  });

  test('Web 桩语义（VM 侧验证）：任何输入恒返回 null', () async {
    final file = await _writePng('${tempDir.path}/c.png', width: 4, height: 4);
    final bytes = img.encodePng(img.Image(width: 4, height: 4));

    expect(
      await probe_stub.probeImageDimensions(
        ImageDimensionProbeInput(localPath: file.path),
      ),
      isNull,
    );
    expect(
      await probe_stub.probeImageDimensions(
        ImageDimensionProbeInput(base64: base64Encode(bytes)),
      ),
      isNull,
    );
  });
}

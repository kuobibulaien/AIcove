/// 原生平台实现：后台 isolate 内做「元数据探测」（`startDecode` 头信息，
/// 不解码像素帧；仍需读取完整编码字节），失败回退整图解码。
///
/// 主 isolate 上不做任何解码工作。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'probe_types.dart';

/// 探测图片尺寸；在后台 isolate 执行，任何失败均返回 null，绝不抛出。
Future<ImageDimensions?> probeImageDimensions(ImageDimensionProbeInput input) {
  return Isolate.run(() => _probeSync(input));
}

final RegExp _whitespacePattern = RegExp(r'\s');

ImageDimensions? _probeSync(ImageDimensionProbeInput input) {
  final localPath = input.localPath?.trim();
  if (localPath != null && localPath.isNotEmpty) {
    final dimensions = _probeFileSync(localPath, input.byteLimit);
    if (dimensions != null) {
      return ImageDimensions(
        width: dimensions.$1,
        height: dimensions.$2,
        hitSource: ImageDimensionProbeSource.localPath,
      );
    }
  }

  final fileUrl = input.fileUrl?.trim();
  if (fileUrl != null && fileUrl.startsWith('file://')) {
    String? filePath;
    try {
      filePath = Uri.parse(fileUrl).toFilePath();
    } on Object {
      filePath = null;
    }
    if (filePath != null && filePath.trim().isNotEmpty) {
      final dimensions = _probeFileSync(filePath, input.byteLimit);
      if (dimensions != null) {
        return ImageDimensions(
          width: dimensions.$1,
          height: dimensions.$2,
          hitSource: ImageDimensionProbeSource.fileUrl,
        );
      }
    }
  }

  final base64Source = input.base64?.trim();
  if (base64Source != null && base64Source.isNotEmpty) {
    final dimensions = _probeBase64Sync(base64Source, input.byteLimit);
    if (dimensions != null) {
      return ImageDimensions(
        width: dimensions.$1,
        height: dimensions.$2,
        hitSource: ImageDimensionProbeSource.base64,
      );
    }
  }

  return null;
}

(int, int)? _probeFileSync(String path, int byteLimit) {
  try {
    final file = File(path);
    if (!file.existsSync()) {
      return null;
    }
    // 大块分配前预检：文件长度超限直接放弃该来源。
    if (file.lengthSync() > byteLimit) {
      return null;
    }
    return _probeBytesSync(file.readAsBytesSync());
  } on Object {
    return null;
  }
}

(int, int)? _probeBase64Sync(String source, int byteLimit) {
  try {
    var payload = source;
    if (payload.startsWith('data:')) {
      final commaIndex = payload.indexOf(',');
      if (commaIndex < 0) {
        return null;
      }
      payload = payload.substring(commaIndex + 1);
    }
    payload = payload.replaceAll(_whitespacePattern, '');
    if (payload.isEmpty) {
      return null;
    }
    // 大块分配前预检：按规范化 payload 长度估算解码后大小。
    final estimatedBytes = (payload.length * 3) ~/ 4;
    if (estimatedBytes > byteLimit) {
      return null;
    }
    final bytes = base64Decode(payload);
    // 解码后二次校验（防御性保留：对合法带 padding 的 base64，
    // 估算值 (len*3)~/4 恒 ≥ 实际解码尺寸，常规输入不可达此分支）。
    if (bytes.length > byteLimit) {
      return null;
    }
    return _probeBytesSync(bytes);
  } on Object {
    return null;
  }
}

(int, int)? _probeBytesSync(Uint8List bytes) {
  try {
    final decoder = img.findDecoderForData(bytes);
    if (decoder != null) {
      final info = decoder.startDecode(bytes);
      if (info != null && info.width > 0 && info.height > 0) {
        return (info.width, info.height);
      }
    }
  } on Object {
    // 头信息解析失败，回退整图解码。
  }
  // 整图回退（防御性保留：image 包的 decodeImage 同样先走
  // findDecoderForData，能构造「头解析失败但整图成功」的输入极少见，
  // 常规输入不可达；保留以兜底 startDecode 抛错/给出无效尺寸的解码器）。
  try {
    final decoded = img.decodeImage(bytes);
    if (decoded != null && decoded.width > 0 && decoded.height > 0) {
      return (decoded.width, decoded.height);
    }
  } on Object {
    // ignore：损坏图片按失败处理。
  }
  return null;
}

/// 图片尺寸探测的平台无关契约。
///
/// 与平台实现解耦：原生实现见 `probe_io.dart`（后台 isolate 元数据探测），
/// Web 桩见 `probe_stub.dart`（恒返回 null，禁用遗留尺寸回填）。
library;

/// 默认单次探测允许读取的最大编码字节数（32MB）。
///
/// 上限在大块分配前预检：文件用 `File.length()`，base64 用解码尺寸估算。
const int kImageDimensionProbeDefaultByteLimit = 32 * 1024 * 1024;

/// 探测命中的来源类型。
enum ImageDimensionProbeSource {
  localPath,
  fileUrl,
  base64,
}

/// 图片尺寸探测输入：携带块上全部可用来源，由实现按
/// localPath → file:// → base64 的优先级依次尝试。
///
/// 字段保持原始（未规范化）值；规范化仅用于调用方的来源身份判定。
class ImageDimensionProbeInput {
  const ImageDimensionProbeInput({
    this.localPath,
    this.fileUrl,
    this.base64,
    this.byteLimit = kImageDimensionProbeDefaultByteLimit,
  });

  /// 本地文件路径来源。
  final String? localPath;

  /// `file://` URL 来源。
  final String? fileUrl;

  /// base64（或 data URL）来源。
  final String? base64;

  /// 单来源允许读取的最大编码字节数；测试可注入小值。
  final int byteLimit;
}

/// 探测结果：尺寸＋实际命中的来源。
class ImageDimensions {
  const ImageDimensions({
    required this.width,
    required this.height,
    required this.hitSource,
  });

  final int width;
  final int height;

  /// 实际命中的来源。
  ///
  /// 仅为 probe 层的可观测性字段（probe 单测消费，用于验证多来源回退
  /// 顺序）；调用方（时间线缓存）的正确性决策不读取它——来源身份与
  /// 写回目标由复合来源身份（指纹＋规范化精确比较）决定。
  final ImageDimensionProbeSource hitSource;
}

/// 图片尺寸探测函数契约。
///
/// 返回 null 表示本次探测失败（来源不可用/超限/损坏/平台禁用）；
/// 实现不得抛出未处理异常。
typedef ImageDimensionProbe = Future<ImageDimensions?> Function(
  ImageDimensionProbeInput input,
);

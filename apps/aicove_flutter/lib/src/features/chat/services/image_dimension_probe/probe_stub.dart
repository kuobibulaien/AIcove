/// Web 平台桩：本次任务禁用 Web 的遗留尺寸回填。
///
/// 恒返回 null——调用方（时间线缓存）对每个来源恰好探测一次即记入
/// attempted 状态，随后静默收敛；不在主线程解码、无 `Isolate.run` 路径。
library;

import 'probe_types.dart';

/// Web 桩实现：任何输入都返回 null，不抛异常。
Future<ImageDimensions?> probeImageDimensions(
  ImageDimensionProbeInput input,
) async {
  return null;
}

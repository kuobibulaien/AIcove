/// 图片尺寸探测门面：平台条件解析实现＋唯一注入点 provider。
///
/// 原生（有 `dart:io`）：`probe_io.dart`，后台 isolate 元数据探测；
/// Web：`probe_stub.dart`，恒返回 null（本次禁用遗留尺寸回填）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'probe_stub.dart' if (dart.library.io) 'probe_io.dart' as impl;
import 'probe_types.dart';

export 'probe_types.dart';

/// 平台条件解析后的探测实现。
const ImageDimensionProbe probeImageDimensions = impl.probeImageDimensions;

/// 唯一注入点：时间线缓存经此 provider 获取探测实现；测试 override 此处。
final imageDimensionProbeProvider = Provider<ImageDimensionProbe>(
  (_) => impl.probeImageDimensions,
);

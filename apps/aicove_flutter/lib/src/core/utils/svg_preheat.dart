/// SVG 图标预热工具
/// 
/// 在 App 启动时预加载 SVG 图标，避免首次进入界面时的卡顿。
library;

import 'package:flutter_svg/flutter_svg.dart';

/// 供应商 SVG 图标路径列表
const List<String> _providerSvgPaths = [
  'assets/icons/providers/openai.svg',
  'assets/icons/providers/openrouter.svg',
  'assets/icons/providers/claude-color.svg',
  'assets/icons/providers/gemini-color.svg',
  'assets/icons/providers/deepseek-color.svg',
  'assets/icons/providers/minimax-color.svg',
  'assets/icons/providers/kimi-color.svg',
  'assets/icons/providers/siliconflow-color.svg',
  'assets/icons/providers/alibabacloud-color.svg',
  'assets/icons/providers/bytedance-color.svg',
];

/// 预热所有供应商 SVG 图标
/// 
/// 将 SVG 解析结果缓存到 flutter_svg 的全局缓存中，
/// 避免首次显示时的解析延迟。
Future<void> preheatProviderSvgIcons() async {
  for (final path in _providerSvgPaths) {
    try {
      // 预加载 SVG 到缓存
      final loader = SvgAssetLoader(path);
      await svg.cache.putIfAbsent(
        loader.cacheKey(null),
        () => loader.loadBytes(null),
      );
    } catch (_) {
      // 忽略加载失败的图标（可能不存在）
    }
  }
}

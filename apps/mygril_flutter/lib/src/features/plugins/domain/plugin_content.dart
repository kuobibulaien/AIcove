import 'package:flutter/widgets.dart';

/// 插件返回的内容基类
/// 使用 sealed class 确保类型安全和穷尽匹配
sealed class PluginContent {
  const PluginContent();
}

/// 纯文本内容
class PluginTextContent extends PluginContent {
  final String text;
  const PluginTextContent(this.text);
}

/// 图片内容
class PluginImageContent extends PluginContent {
  /// 本地文件路径
  final String localPath;
  
  /// 可选的图片说明
  final String? caption;
  
  const PluginImageContent(this.localPath, {this.caption});
}

/// 音频内容
class PluginAudioContent extends PluginContent {
  /// 本地文件路径
  final String localPath;
  
  /// 音频时长（可选）
  final Duration? duration;
  
  const PluginAudioContent(this.localPath, {this.duration});
}

/// 自定义 UI 组件内容（高级特性）
/// 允许插件返回任意 Flutter Widget
class PluginWidgetContent extends PluginContent {
  final Widget widget;
  const PluginWidgetContent(this.widget);
}

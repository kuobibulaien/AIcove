/// 插件生命周期状态
enum PluginState {
  /// 未初始化（刚创建）
  uninitialized,

  /// 初始化中
  initializing,

  /// 就绪（初始化完成，但未启用）
  ready,

  /// 已启用（正常工作）
  enabled,

  /// 已禁用（暂停工作）
  disabled,

  /// 出错
  error,

  /// 已销毁（资源已释放）
  destroyed,
}

/// 状态扩展方法
extension PluginStateExtension on PluginState {
  /// 是否可以启用
  bool get canEnable => this == PluginState.ready || this == PluginState.disabled;

  /// 是否可以禁用
  bool get canDisable => this == PluginState.enabled;

  /// 是否正在工作
  bool get isWorking => this == PluginState.enabled;

  /// 状态的中文描述
  String get displayName {
    switch (this) {
      case PluginState.uninitialized:
        return '未初始化';
      case PluginState.initializing:
        return '初始化中';
      case PluginState.ready:
        return '就绪';
      case PluginState.enabled:
        return '已启用';
      case PluginState.disabled:
        return '已禁用';
      case PluginState.error:
        return '出错';
      case PluginState.destroyed:
        return '已销毁';
    }
  }
}

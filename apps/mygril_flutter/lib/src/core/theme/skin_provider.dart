/// SkinProvider - 皮肤状态管理
/// 
/// 使用 Riverpod 管理当前选中的皮肤，支持运行时切换。
/// 
/// 更新记录：
/// - 2025-12-06: 创建皮肤状态管理
/// - 2025-12-06: 添加 SkinScope InheritedWidget
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'skin_config.dart';
import 'skins/moetalk_skin.dart';

/// 所有可用皮肤列表
final availableSkinsProvider = Provider<List<SkinConfig>>((ref) {
  return const [
    MoeTalkSkin(),
    // TODO: 添加更多皮肤
    // GlassmorphismSkin(),
    // ForestBookSkin(),
  ];
});

/// 当前选中的皮肤
final currentSkinProvider = StateNotifierProvider<SkinNotifier, SkinConfig>((ref) {
  return SkinNotifier();
});

/// 皮肤状态管理器
class SkinNotifier extends StateNotifier<SkinConfig> {
  SkinNotifier() : super(const MoeTalkSkin());
  
  /// 切换皮肤
  void changeTo(SkinConfig skin) {
    state = skin;
  }
  
  /// 根据 ID 切换皮肤
  void changeById(String skinId, List<SkinConfig> availableSkins) {
    final skin = availableSkins.firstWhere(
      (s) => s.id == skinId,
      orElse: () => const MoeTalkSkin(),
    );
    state = skin;
  }
}

/// 便捷扩展：从 WidgetRef 获取当前皮肤
extension SkinRefExtension on WidgetRef {
  SkinConfig get skin => watch(currentSkinProvider);
}

// ===== 通过 InheritedWidget 提供皮肤（供非 Consumer 组件使用） =====

/// 皮肤作用域，包装在 MaterialApp 外层
class SkinScope extends InheritedWidget {
  final SkinConfig skin;
  
  const SkinScope({
    super.key,
    required this.skin,
    required super.child,
  });
  
  static SkinConfig of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<SkinScope>();
    return scope?.skin ?? const MoeTalkSkin();
  }
  
  @override
  bool updateShouldNotify(SkinScope oldWidget) => skin.id != oldWidget.skin.id;
}

/// 便捷扩展：从 BuildContext 获取当前皮肤
extension SkinContextExtension on BuildContext {
  SkinConfig get skin => SkinScope.of(this);
}

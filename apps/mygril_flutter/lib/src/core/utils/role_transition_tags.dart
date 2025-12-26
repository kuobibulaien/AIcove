/// 角色卡 Hero 动画 tag 统一管理
///
/// 避免 tag 字符串散落在多个页面导致冲突或拼写错误
///
/// 更新记录：
/// - 2025-12-27: 创建，用于角色卡背景展开动效
class RoleTransitionTags {
  RoleTransitionTags._();

  /// 背景 Hero tag
  static String bg(String id) => 'role_bg_$id';

  /// 人物海报 Hero tag（与现有保持一致）
  static String image(String id) => 'role_image_$id';

  /// 名字 Hero tag
  static String name(String id) => 'role_name_$id';

  /// 简介框 Hero tag
  static String intro(String id) => 'role_intro_$id';
}

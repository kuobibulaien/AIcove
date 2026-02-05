import 'config_field_type.dart';

/// 配置字段定义
/// 用于描述插件的一个配置项，系统可根据此定义自动生成配置 UI
class ConfigField {
  /// 字段类型
  final ConfigFieldType type;

  /// 显示标签
  final String label;

  /// 描述/提示文字（可选）
  final String? description;

  /// 默认值（可选）
  final dynamic defaultValue;

  /// 是否必填
  final bool required;

  /// 选项列表（当 type 为 select 或 multiSelect 时使用）
  final List<String>? options;

  /// 验证规则（可选，如正则表达式）
  final String? validationPattern;

  /// 验证失败时的错误提示
  final String? validationError;

  const ConfigField({
    required this.type,
    required this.label,
    this.description,
    this.defaultValue,
    this.required = false,
    this.options,
    this.validationPattern,
    this.validationError,
  }) : assert(
         type != ConfigFieldType.select || options != null,
         'select 类型必须提供 options',
       );

  /// 验证值是否合法
  bool validate(dynamic value) {
    // 必填检查
    if (required && (value == null || value.toString().isEmpty)) {
      return false;
    }

    // 类型检查
    if (value != null) {
      switch (type) {
        case ConfigFieldType.string:
          if (value is! String) return false;
        case ConfigFieldType.integer:
          if (value is! int) return false;
        case ConfigFieldType.number:
          if (value is! num) return false;
        case ConfigFieldType.boolean:
          if (value is! bool) return false;
        case ConfigFieldType.select:
          if (!options!.contains(value)) return false;
        case ConfigFieldType.multiSelect:
          if (value is! List || !value.every(options!.contains)) return false;
      }

      // 正则验证
      if (validationPattern != null && value is String) {
        final regex = RegExp(validationPattern!);
        if (!regex.hasMatch(value)) return false;
      }
    }

    return true;
  }
}

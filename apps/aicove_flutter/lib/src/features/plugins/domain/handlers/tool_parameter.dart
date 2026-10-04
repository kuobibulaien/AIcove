/// 工具参数定义
class ToolParameter {
  /// 参数类型（string, number, boolean, object, array）
  final String type;

  /// 参数描述（给 AI 看的）
  final String description;

  /// 是否必填
  final bool required;

  /// 枚举值（可选）
  final List<String>? enumValues;

  /// 数组元素的 JSON Schema（type 为 array 时使用，部分供应商要求必填）
  final Map<String, dynamic>? items;

  const ToolParameter({
    required this.type,
    required this.description,
    this.required = false,
    this.enumValues,
    this.items,
  });

  /// 转为 JSON Schema 格式
  Map<String, dynamic> toJsonSchema() {
    final schema = <String, dynamic>{
      'type': type,
      'description': description,
    };
    
    if (enumValues != null && enumValues!.isNotEmpty) {
      schema['enum'] = enumValues;
    }

    if (items != null) {
      schema['items'] = items;
    }
    
    return schema;
  }
}

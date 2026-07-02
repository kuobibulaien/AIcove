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

  const ToolParameter({
    required this.type,
    required this.description,
    this.required = false,
    this.enumValues,
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
    
    return schema;
  }
}

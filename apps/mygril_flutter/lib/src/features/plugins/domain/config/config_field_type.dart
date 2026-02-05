/// 配置字段类型
enum ConfigFieldType {
  /// 字符串
  string,

  /// 整数
  integer,

  /// 浮点数
  number,

  /// 布尔值
  boolean,

  /// 单选（需提供 options）
  select,

  /// 多选（需提供 options）
  multiSelect,
}

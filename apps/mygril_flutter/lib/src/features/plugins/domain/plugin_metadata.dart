import 'package:flutter/material.dart';
import 'config/config_field.dart';

/// 插件元数据
/// 描述插件的基本信息、版本、作者、配置模板等
class PluginMetadata {
  /// 唯一标识符（建议用反向域名，如 com.mygril.tts）
  final String id;

  /// 显示名称
  final String name;

  /// 描述
  final String description;

  /// 版本号（语义化版本，如 1.0.0）
  final String version;

  /// 作者
  final String author;

  /// 图标
  final IconData icon;

  /// 主页/仓库地址（可选）
  final String? homepage;

  /// 最低 App 版本要求（可选，如 "1.0.0"）
  final String? minAppVersion;

  /// 依赖的其他插件 ID 列表（可选）
  final List<String> dependencies;

  /// 配置项定义（用于自动生成配置 UI）
  final Map<String, ConfigField> configSchema;

  const PluginMetadata({
    required this.id,
    required this.name,
    required this.description,
    required this.version,
    required this.author,
    required this.icon,
    this.homepage,
    this.minAppVersion,
    this.dependencies = const [],
    this.configSchema = const {},
  });

  /// 复制并修改部分字段
  PluginMetadata copyWith({
    String? id,
    String? name,
    String? description,
    String? version,
    String? author,
    IconData? icon,
    String? homepage,
    String? minAppVersion,
    List<String>? dependencies,
    Map<String, ConfigField>? configSchema,
  }) {
    return PluginMetadata(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      version: version ?? this.version,
      author: author ?? this.author,
      icon: icon ?? this.icon,
      homepage: homepage ?? this.homepage,
      minAppVersion: minAppVersion ?? this.minAppVersion,
      dependencies: dependencies ?? this.dependencies,
      configSchema: configSchema ?? this.configSchema,
    );
  }
}

import 'dart:convert';

import '../../content_tags/domain/content_tag_registry.dart';
import '../../content_tags/domain/content_tag_spec.dart';

/// A declarative package (batch 2 plan §3.6): prompt fragments, semantic tag
/// declarations and Markdown skills. It never contains anything executable;
/// unknown fields reject the whole package.
class AicovePackage {
  const AicovePackage({
    required this.id,
    required this.name,
    required this.version,
    this.description = '',
    this.prompts = const [],
    this.tags = const [],
    this.skills = const [],
  });

  static const manifestName = 'aicove-package.json';

  final String id;
  final String name;
  final String version;
  final String description;
  final List<String> prompts;
  final List<PackageTag> tags;
  final List<PackageSkill> skills;

  /// Plugin id the package is installed under.
  String get pluginId => pluginIdOf(id);

  static String pluginIdOf(String packageId) => 'pkg:$packageId';

  static bool isPackagePluginId(String pluginId) => pluginId.startsWith('pkg:');

  static bool isValidId(String id) => _idPattern.hasMatch(id);

  /// Parses a package from its files (paths relative to the package root,
  /// `/`-separated). Throws [PackageFormatException] on anything not allowed.
  static AicovePackage parse(Map<String, List<int>> files) {
    final manifestBytes = files[manifestName];
    if (manifestBytes == null) {
      throw const PackageFormatException('缺少 $manifestName');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(manifestBytes));
    } on FormatException {
      throw const PackageFormatException('清单不是合法的 JSON');
    }
    final manifest = _object(decoded, '清单');
    _onlyKeys(manifest, const {
      'schema',
      'id',
      'name',
      'version',
      'description',
      'contents',
    }, '清单');
    if (manifest['schema'] != 1) {
      throw const PackageFormatException('只支持 schema 1');
    }
    final id = _string(manifest['id'], 'id');
    if (!_idPattern.hasMatch(id)) {
      throw PackageFormatException('id 只能是小写字母、数字、- 和 _：$id');
    }
    final prompts = <String>[];
    final tags = <PackageTag>[];
    final skills = <PackageSkill>[];
    final referenced = <String>{manifestName};
    final contents = manifest['contents'];
    if (contents is! List || contents.isEmpty) {
      throw const PackageFormatException('contents 必须是非空列表');
    }
    for (final raw in contents) {
      final item = _object(raw, '内容项');
      switch (item['type']) {
        case 'prompt':
          _onlyKeys(item, const {'type', 'text'}, 'prompt');
          prompts.add(_string(item['text'], 'prompt.text'));
        case 'tags':
          _onlyKeys(item, const {'type', 'tags'}, 'tags');
          final list = item['tags'];
          if (list is! List || list.isEmpty) {
            throw const PackageFormatException('tags.tags 必须是非空列表');
          }
          for (final rawTag in list) {
            tags.add(PackageTag._parse(_object(rawTag, '标签')));
          }
        case 'skill':
          _onlyKeys(item, const {'type', 'name', 'title', 'file'}, 'skill');
          final skillName = _string(item['name'], 'skill.name');
          if (!_idPattern.hasMatch(skillName)) {
            throw PackageFormatException('技能名不合法：$skillName');
          }
          if (skills.any((s) => s.name == skillName)) {
            throw PackageFormatException('技能名重复：$skillName');
          }
          final file = _string(item['file'], 'skill.file');
          if (!_isSafeMarkdownPath(file)) {
            throw PackageFormatException('技能文件必须是包内的 .md 文件：$file');
          }
          final bytes = files[file];
          if (bytes == null) throw PackageFormatException('缺少技能文件：$file');
          referenced.add(file);
          final title = item['title'];
          if (title != null && title is! String) {
            throw const PackageFormatException('skill.title 必须是文本');
          }
          skills.add(
            PackageSkill(
              name: skillName,
              title: (title as String?)?.trim() ?? '',
              file: file,
              content: utf8.decode(bytes),
            ),
          );
        default:
          throw PackageFormatException('不支持的内容类型：${item['type']}');
      }
    }
    final extra = files.keys.where((path) => !referenced.contains(path));
    if (extra.isNotEmpty) {
      throw PackageFormatException('包里有未声明的文件：${extra.first}');
    }
    final description = manifest['description'];
    if (description != null && description is! String) {
      throw const PackageFormatException('description 必须是文本');
    }
    return AicovePackage(
      id: id,
      name: _string(manifest['name'], 'name'),
      version: _string(manifest['version'], 'version'),
      description: (description as String?)?.trim() ?? '',
      prompts: prompts,
      tags: tags,
      skills: skills,
    );
  }

  /// Tags the package declares, owned by its plugin id, so the request
  /// copy strips them while the package is off for a role.
  ContentTagProvider contentTagProvider({required String readSkillTool}) =>
      StaticContentTagProvider(
        providerId: pluginId,
        tagSpecs: [
          for (final tag in tags)
            ContentTagSpec(
              name: tag.name,
              ownerId: pluginId,
              aliases: tag.aliases,
              display: tag.hidden
                  ? ContentTagDisplay.hidden
                  : ContentTagDisplay.text,
            ),
        ],
        toolNames: {if (skills.isNotEmpty) readSkillTool},
      );

  static final _idPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,39}$');

  static bool _isSafeMarkdownPath(String path) =>
      path.toLowerCase().endsWith('.md') &&
      !path.startsWith('/') &&
      !path.contains('\\') &&
      !path
          .split('/')
          .any((part) => part.isEmpty || part == '.' || part == '..');

  static Map<String, Object?> _object(Object? value, String what) {
    if (value is Map) return Map<String, Object?>.from(value);
    throw PackageFormatException('$what必须是对象');
  }

  static void _onlyKeys(
    Map<String, Object?> map,
    Set<String> allowed,
    String what,
  ) {
    for (final key in map.keys) {
      if (!allowed.contains(key)) {
        throw PackageFormatException('$what 含有不支持的字段：$key');
      }
    }
  }

  static String _string(Object? value, String what) {
    if (value is String && value.trim().isNotEmpty) return value.trim();
    throw PackageFormatException('$what 必须是非空文本');
  }
}

/// A semantic tag the package declares (ADR0044). Shown as text or hidden;
/// a package cannot declare markup rendering or rewrite rules.
class PackageTag {
  const PackageTag({
    required this.name,
    this.aliases = const {},
    this.hidden = false,
  });

  final String name;
  final Set<String> aliases;
  final bool hidden;

  static final _tagPattern = RegExp(r'^[a-z][a-z0-9_-]{0,31}$');

  static PackageTag _parse(Map<String, Object?> json) {
    AicovePackage._onlyKeys(json, const {'name', 'aliases', 'display'}, '标签');
    String tagName(Object? value) {
      final name = AicovePackage._string(value, '标签名').toLowerCase();
      if (!_tagPattern.hasMatch(name)) {
        throw PackageFormatException('标签名不合法：$name');
      }
      return name;
    }

    final aliases = json['aliases'];
    if (aliases != null && aliases is! List) {
      throw const PackageFormatException('aliases 必须是列表');
    }
    final display = json['display'] ?? 'text';
    if (display != 'text' && display != 'hidden') {
      throw PackageFormatException('标签只能显示为 text 或 hidden：$display');
    }
    return PackageTag(
      name: tagName(json['name']),
      aliases: {
        for (final alias in (aliases as List?) ?? const []) tagName(alias),
      },
      hidden: display == 'hidden',
    );
  }
}

/// A Markdown document the model may read by name through the package's
/// read-skill tool.
class PackageSkill {
  const PackageSkill({
    required this.name,
    required this.title,
    required this.file,
    required this.content,
  });

  final String name;
  final String title;
  final String file;
  final String content;
}

class PackageFormatException implements Exception {
  const PackageFormatException(this.message);

  final String message;

  @override
  String toString() => '声明式包格式错误：$message';
}

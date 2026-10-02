import 'content_tag_spec.dart';

/// 一次请求/一次解析用的标签注册表快照：有哪些提供方、哪些生效。
///
/// 同名标签以先注册的提供方为准（第一方插件先于预设注册）。
class ContentTagRegistry {
  ContentTagRegistry(
    Iterable<ContentTagProvider> providers, {
    Set<String>? activeProviderIds,
  }) : _activeProviderIds = activeProviderIds {
    for (final provider in providers) {
      for (final spec in provider.tagSpecs) {
        for (final name in spec.allNames) {
          _specsByName.putIfAbsent(name.toLowerCase(), () => spec);
        }
      }
      for (final tool in provider.toolNames) {
        _toolOwners.putIfAbsent(tool, () => provider.providerId);
      }
    }
  }

  final Map<String, ContentTagSpec> _specsByName = {};
  final Map<String, String> _toolOwners = {};

  /// null 表示全部生效（落库拆分、显示等与开关无关的场景）。
  final Set<String>? _activeProviderIds;

  Iterable<String> get tagNames => _specsByName.keys;

  ContentTagSpec? lookup(String tagName) =>
      _specsByName[tagName.toLowerCase()];

  bool isOwnerActive(String ownerId) =>
      ownerId == ContentTagSpec.builtinOwnerId ||
      (_activeProviderIds?.contains(ownerId) ?? true);

  bool isActive(ContentTagSpec spec) => isOwnerActive(spec.ownerId);

  ContentTagRequestAction requestAction(ContentTagSpec spec) => isActive(spec)
      ? spec.requestWhenActive
      : spec.requestWhenInactive;

  /// 未登记归属的工具一律放行。
  bool allowsTool(String name) {
    final owner = _toolOwners[name];
    return owner == null || isOwnerActive(owner);
  }
}

/// 简单的数据型提供方，供插件静态声明或测试使用。
class StaticContentTagProvider implements ContentTagProvider {
  const StaticContentTagProvider({
    required this.providerId,
    required this.tagSpecs,
    this.toolNames = const <String>{},
  });

  @override
  final String providerId;
  @override
  final List<ContentTagSpec> tagSpecs;
  @override
  final Set<String> toolNames;
}

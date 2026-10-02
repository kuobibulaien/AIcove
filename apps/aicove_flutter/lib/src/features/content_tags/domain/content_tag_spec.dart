/// 语义标签声明（ADR0044）。
///
/// 插件（第一方）与预设（第三方）都是内容扩展：声明自己拥有的语义标签，
/// 请求副本、落库拆分与流式显示统一按声明处理，不再各写正则。
library;

/// 请求副本里如何处理一个标签。raw 原文永远不改。
enum ContentTagRequestAction {
  /// 原样保留（内部仍会继续按其他标签的策略过滤）。
  keep,

  /// 连同正文一起删除。
  strip,

  /// 去掉外壳，只留正文。
  unwrap,
}

/// 显示层如何呈现一个标签。
enum ContentTagDisplay {
  /// 原样显示为文本。
  text,

  /// 不显示（连同正文）。
  hidden,

  /// 语音片段。
  tts,

  /// 生图占位。
  image,
}

class ContentTagSpec {
  const ContentTagSpec({
    required this.name,
    required this.ownerId,
    this.aliases = const <String>{},
    this.requestWhenActive = ContentTagRequestAction.keep,
    this.requestWhenInactive = ContentTagRequestAction.strip,
    this.display = ContentTagDisplay.text,
    this.displayRequiresBareTag = false,
  });

  /// 小写标签名。
  final String name;

  /// 同义标签名（小写）。
  final Set<String> aliases;

  /// 提供方 id：插件 id、`preset:<recipeId>` 或 [builtinOwnerId]。
  final String ownerId;

  final ContentTagRequestAction requestWhenActive;
  final ContentTagRequestAction requestWhenInactive;
  final ContentTagDisplay display;

  /// 为 true 时，带属性的同名标签（如 `<image source="history">`）不按
  /// [display] 呈现，而是作为普通文本保留。
  final bool displayRequiresBareTag;

  static const String builtinOwnerId = 'builtin';

  Iterable<String> get allNames sync* {
    yield name;
    yield* aliases;
  }
}

/// 内容扩展：插件与预设都实现它，向注册表提供标签与工具归属。
abstract interface class ContentTagProvider {
  String get providerId;
  List<ContentTagSpec> get tagSpecs;

  /// 归属该提供方的工具名；提供方未生效时，请求副本成对移除这些工具调用。
  Set<String> get toolNames;
}

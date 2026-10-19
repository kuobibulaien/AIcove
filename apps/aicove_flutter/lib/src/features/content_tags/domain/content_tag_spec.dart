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
    this.jsonPayload = false,
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

  /// 正文是 JSON 数据（如 `<JSONPatch>`）：字符串字面量里出现的闭标签不算结束。
  final bool jsonPayload;

  static const String builtinOwnerId = 'builtin';

  Iterable<String> get allNames sync* {
    yield name;
    yield* aliases;
  }
}

/// 系统事件标签：宿主写在消息正文开头的 `[名称：详情]`，结构化数据存在
/// 消息块里，模型与旧客户端只看到这段正文（ADR0074 通话记录、ADR0088 回执）。
/// 不经 [ContentTagSpec] 的尖括号扫描，按正文开头匹配。
class ContentEventLabelSpec {
  const ContentEventLabelSpec({required this.name, required this.ownerId});

  final String name;

  /// 提供方 id，同 [ContentTagSpec.ownerId]。
  final String ownerId;

  String format(String detail) => '[$name：$detail]';

  /// 正文以本标签开头时返回详情，否则返回 null。
  String? detailOf(String text) {
    final head = '[$name：';
    final trimmed = text.trimLeft();
    if (!trimmed.startsWith(head)) return null;
    final end = trimmed.indexOf(']', head.length);
    return end < 0 ? null : trimmed.substring(head.length, end);
  }
}

/// 内容扩展：插件与预设都实现它，向注册表提供标签与工具归属。
abstract interface class ContentTagProvider {
  String get providerId;
  List<ContentTagSpec> get tagSpecs;

  /// 本提供方写入的系统事件标签。
  List<ContentEventLabelSpec> get eventLabels;

  /// 归属该提供方的工具名；提供方未生效时，请求副本成对移除这些工具调用。
  Set<String> get toolNames;
}

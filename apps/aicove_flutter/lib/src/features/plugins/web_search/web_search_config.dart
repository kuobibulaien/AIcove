/// 联网搜索插件配置。
///
/// 搜索供应商像模型渠道一样按列表管理：可添加多家，按顺序优先使用，
/// 前一家失败自动换下一家（见 [WebSearchService]）。没有可用供应商时
/// 插件视为不可用，不会向模型提供工具。
library;

/// 支持的搜索供应商类型。
enum WebSearchProviderType {
  exa(
    id: 'exa',
    label: 'Exa',
    defaultBaseUrl: 'https://api.exa.ai',
    keyHint: '在 dashboard.exa.ai 创建',
    supportsFetch: true,
  ),
  tavily(
    id: 'tavily',
    label: 'Tavily',
    defaultBaseUrl: 'https://api.tavily.com',
    keyHint: '在 app.tavily.com 创建',
    supportsFetch: true,
  ),
  brave(
    id: 'brave',
    label: 'Brave Search',
    defaultBaseUrl: 'https://api.search.brave.com',
    keyHint: '在 api-dashboard.search.brave.com 创建',
  ),
  bocha(
    id: 'bocha',
    label: '博查',
    defaultBaseUrl: 'https://api.bochaai.com',
    keyHint: '在 open.bochaai.com 创建',
  ),
  zhipu(
    id: 'zhipu',
    label: '智谱',
    defaultBaseUrl: 'https://open.bigmodel.cn/api',
    keyHint: '在 bigmodel.cn 控制台创建',
  ),
  perplexity(
    id: 'perplexity',
    label: 'Perplexity',
    defaultBaseUrl: 'https://api.perplexity.ai',
    keyHint: '在 perplexity.ai 的 API 设置中创建',
  ),
  jina(
    id: 'jina',
    label: 'Jina',
    defaultBaseUrl: 'https://s.jina.ai',
    keyHint: '在 jina.ai 创建',
    supportsFetch: true,
  ),
  firecrawl(
    id: 'firecrawl',
    label: 'Firecrawl',
    defaultBaseUrl: 'https://api.firecrawl.dev',
    keyHint: '在 firecrawl.dev 创建',
    supportsFetch: true,
  ),
  serper(
    id: 'serper',
    label: 'Serper（Google）',
    defaultBaseUrl: 'https://google.serper.dev',
    keyHint: '在 serper.dev 创建',
  ),
  searxng(
    id: 'searxng',
    label: 'SearXNG（自建）',
    defaultBaseUrl: '',
    keyHint: '自建实例通常不需要密钥',
    requiresApiKey: false,
  );

  const WebSearchProviderType({
    required this.id,
    required this.label,
    required this.defaultBaseUrl,
    required this.keyHint,
    this.requiresApiKey = true,
    this.supportsFetch = false,
  });

  final String id;
  final String label;

  /// 官方接口地址；为空表示必须由用户填写（自建服务）。
  final String defaultBaseUrl;
  final String keyHint;
  final bool requiresApiKey;

  /// 是否自带网页正文读取接口；不支持的由插件直接抓取网页兜底。
  final bool supportsFetch;

  static WebSearchProviderType? fromId(String? id) {
    for (final type in values) {
      if (type.id == id) return type;
    }
    return null;
  }
}

/// 一家搜索供应商的配置。
class WebSearchProviderEntry {
  final String id;
  final WebSearchProviderType type;

  /// 显示名称；为空时显示供应商类型名。
  final String name;
  final String apiKey;

  /// 接口地址，留空使用官方地址；可填兼容该协议的代理。
  final String baseUrl;
  final bool enabled;

  const WebSearchProviderEntry({
    required this.id,
    required this.type,
    this.name = '',
    this.apiKey = '',
    this.baseUrl = '',
    this.enabled = true,
  });

  factory WebSearchProviderEntry.create(WebSearchProviderType type) =>
      WebSearchProviderEntry(
        id: 'ws_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
        type: type,
      );

  String get displayName => name.trim().isEmpty ? type.label : name.trim();

  String get effectiveBaseUrl {
    final trimmed = baseUrl.trim();
    final base = trimmed.isEmpty ? type.defaultBaseUrl : trimmed;
    return base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  }

  /// 已填好必需项（密钥、自建地址），可以发起请求。
  bool get isReady =>
      (!type.requiresApiKey || apiKey.trim().isNotEmpty) &&
      effectiveBaseUrl.isNotEmpty;

  bool get isUsable => enabled && isReady;

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.id,
    'name': name,
    'apiKey': apiKey,
    'baseUrl': baseUrl,
    'enabled': enabled,
  };

  /// 未知类型（来自更新版本的同步数据）返回 null，由调用方跳过。
  static WebSearchProviderEntry? fromJson(Map<String, dynamic> json) {
    final type = WebSearchProviderType.fromId(json['type'] as String?);
    final id = (json['id'] as String?)?.trim() ?? '';
    if (type == null || id.isEmpty) return null;
    return WebSearchProviderEntry(
      id: id,
      type: type,
      name: json['name'] as String? ?? '',
      apiKey: json['apiKey'] as String? ?? '',
      baseUrl: json['baseUrl'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  WebSearchProviderEntry copyWith({
    String? name,
    String? apiKey,
    String? baseUrl,
    bool? enabled,
  }) {
    return WebSearchProviderEntry(
      id: id,
      type: type,
      name: name ?? this.name,
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      enabled: enabled ?? this.enabled,
    );
  }
}

class WebSearchConfig {
  static const int minResults = 1;
  static const int maxResults = 10;
  static const int defaultNumResults = 5;
  static const int minCharacters = 200;
  static const int maxCharacters = 10000;
  static const int defaultMaxCharacters = 1500;

  /// 按优先级排列的搜索供应商。
  final List<WebSearchProviderEntry> providers;

  /// 为 true 时，本插件生效的请求会去掉模型内置搜索参数，统一用本插件搜索。
  final bool replaceModelBuiltinSearch;

  /// 单次搜索返回的结果条数。
  final int numResults;

  /// 每条结果（或每个网页）带回给模型的最大正文字符数。
  final int maxCharactersPerResult;

  const WebSearchConfig({
    this.providers = const [],
    this.replaceModelBuiltinSearch = false,
    this.numResults = defaultNumResults,
    this.maxCharactersPerResult = defaultMaxCharacters,
  });

  List<WebSearchProviderEntry> get usableProviders =>
      [for (final p in providers) if (p.isUsable) p];

  bool get isConfigured => providers.any((p) => p.isUsable);

  Map<String, dynamic> toJson() => {
    'providers': [for (final p in providers) p.toJson()],
    'replaceModelBuiltinSearch': replaceModelBuiltinSearch,
    'numResults': numResults,
    'maxCharactersPerResult': maxCharactersPerResult,
  };

  factory WebSearchConfig.fromJson(Map<String, dynamic> json) {
    final rawProviders = json['providers'];
    final providers = <WebSearchProviderEntry>[
      if (rawProviders is List)
        for (final item in rawProviders)
          if (item is Map)
            ?WebSearchProviderEntry.fromJson(Map<String, dynamic>.from(item)),
    ];
    // 早期单供应商格式：顶层 apiKey/baseUrl 只对应 Exa。
    final legacyKey = (json['apiKey'] as String?)?.trim() ?? '';
    if (rawProviders == null && legacyKey.isNotEmpty) {
      providers.add(
        WebSearchProviderEntry(
          id: 'ws_legacy_exa',
          type: WebSearchProviderType.exa,
          apiKey: legacyKey,
          baseUrl: json['baseUrl'] as String? ?? '',
        ),
      );
    }
    return WebSearchConfig(
      providers: List.unmodifiable(providers),
      replaceModelBuiltinSearch:
          json['replaceModelBuiltinSearch'] as bool? ?? false,
      numResults: ((json['numResults'] as num?)?.toInt() ?? defaultNumResults)
          .clamp(minResults, maxResults),
      maxCharactersPerResult:
          ((json['maxCharactersPerResult'] as num?)?.toInt() ??
                  defaultMaxCharacters)
              .clamp(minCharacters, maxCharacters),
    );
  }

  WebSearchConfig copyWith({
    List<WebSearchProviderEntry>? providers,
    bool? replaceModelBuiltinSearch,
    int? numResults,
    int? maxCharactersPerResult,
  }) {
    return WebSearchConfig(
      providers: providers == null
          ? this.providers
          : List.unmodifiable(providers),
      replaceModelBuiltinSearch:
          replaceModelBuiltinSearch ?? this.replaceModelBuiltinSearch,
      numResults: numResults ?? this.numResults,
      maxCharactersPerResult:
          maxCharactersPerResult ?? this.maxCharactersPerResult,
    );
  }
}

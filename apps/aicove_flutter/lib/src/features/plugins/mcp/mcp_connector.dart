/// MCP 连接器配置：用户自己接入的远程 MCP 服务（Streamable HTTP）。
///
/// 每个连接器在插件层表现为一个独立插件 `mcp:<id>`，由角色在「管理开启的插件」
/// 里逐个开启；工具清单在测试连接／刷新时拉取并随配置保存，请求时不再联网列举。
library;

/// 服务端声明的一个工具（tools/list 的条目）。
class McpToolInfo {
  const McpToolInfo({
    required this.name,
    this.title = '',
    this.description = '',
    this.inputSchema = const <String, dynamic>{},
  });

  final String name;
  final String title;
  final String description;
  final Map<String, dynamic> inputSchema;

  String get displayName => title.trim().isEmpty ? name : title.trim();

  factory McpToolInfo.fromJson(Map<String, dynamic> json) => McpToolInfo(
    name: (json['name'] ?? '').toString(),
    title: (json['title'] ?? '').toString(),
    description: (json['description'] ?? '').toString(),
    inputSchema: json['inputSchema'] is Map
        ? Map<String, dynamic>.from(json['inputSchema'] as Map)
        : const <String, dynamic>{},
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    if (title.isNotEmpty) 'title': title,
    if (description.isNotEmpty) 'description': description,
    'inputSchema': inputSchema,
  };
}

class McpConnector {
  const McpConnector({
    required this.id,
    this.name = '',
    this.url = '',
    this.bearerToken = '',
    this.headers = const <String, String>{},
    this.enabled = true,
    this.tools = const <McpToolInfo>[],
    this.disabledTools = const <String>{},
    this.serverName = '',
    this.toolsFetchedAt,
  });

  /// 只含小写字母与数字，参与工具名拼接（见 [McpToolNaming]）。
  final String id;
  final String name;
  final String url;

  /// 非空时作为 `Authorization: Bearer <token>` 发送。
  final String bearerToken;

  /// 额外请求头（如服务要求的自定义鉴权头）。
  final Map<String, String> headers;
  final bool enabled;

  /// 最近一次成功列举到的工具；为空表示尚未连接成功。
  final List<McpToolInfo> tools;

  /// 用户在连接器里关掉的工具（按服务端原名）。
  final Set<String> disabledTools;

  /// initialize 返回的服务名，仅用于展示。
  final String serverName;
  final DateTime? toolsFetchedAt;

  factory McpConnector.create() =>
      McpConnector(id: DateTime.now().microsecondsSinceEpoch.toRadixString(36));

  String get displayName {
    if (name.trim().isNotEmpty) return name.trim();
    if (serverName.trim().isNotEmpty) return serverName.trim();
    final host = Uri.tryParse(url.trim())?.host ?? '';
    return host.isEmpty ? 'MCP 连接器' : host;
  }

  bool get hasValidUrl {
    final uri = Uri.tryParse(url.trim());
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  /// 已启用、地址有效且拿到过工具清单，才会向模型提供工具。
  bool get isUsable => enabled && hasValidUrl && tools.isNotEmpty;

  List<McpToolInfo> get activeTools => [
    for (final tool in tools)
      if (!disabledTools.contains(tool.name)) tool,
  ];

  /// 实际发送的请求头；Bearer 令牌优先于同名自定义头。
  Map<String, String> get requestHeaders => {
    for (final entry in headers.entries)
      if (entry.key.trim().isNotEmpty) entry.key.trim(): entry.value.trim(),
    if (bearerToken.trim().isNotEmpty)
      'Authorization': 'Bearer ${bearerToken.trim()}',
  };

  McpConnector copyWith({
    String? name,
    String? url,
    String? bearerToken,
    Map<String, String>? headers,
    bool? enabled,
    List<McpToolInfo>? tools,
    Set<String>? disabledTools,
    String? serverName,
    DateTime? toolsFetchedAt,
  }) => McpConnector(
    id: id,
    name: name ?? this.name,
    url: url ?? this.url,
    bearerToken: bearerToken ?? this.bearerToken,
    headers: headers ?? this.headers,
    enabled: enabled ?? this.enabled,
    tools: tools ?? this.tools,
    disabledTools: disabledTools ?? this.disabledTools,
    serverName: serverName ?? this.serverName,
    toolsFetchedAt: toolsFetchedAt ?? this.toolsFetchedAt,
  );

  factory McpConnector.fromJson(Map<String, dynamic> json) => McpConnector(
    id: (json['id'] ?? '').toString(),
    name: (json['name'] ?? '').toString(),
    url: (json['url'] ?? '').toString(),
    bearerToken: (json['bearerToken'] ?? '').toString(),
    headers: json['headers'] is Map
        ? {
            for (final entry in (json['headers'] as Map).entries)
              entry.key.toString(): entry.value.toString(),
          }
        : const <String, String>{},
    enabled: json['enabled'] as bool? ?? true,
    tools: [
      for (final item in json['tools'] as List? ?? const [])
        if (item is Map) McpToolInfo.fromJson(Map<String, dynamic>.from(item)),
    ],
    disabledTools: {
      for (final item in json['disabledTools'] as List? ?? const [])
        item.toString(),
    },
    serverName: (json['serverName'] ?? '').toString(),
    toolsFetchedAt: DateTime.tryParse(
      (json['toolsFetchedAt'] ?? '').toString(),
    ),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'bearerToken': bearerToken,
    'headers': headers,
    'enabled': enabled,
    'tools': [for (final tool in tools) tool.toJson()],
    'disabledTools': disabledTools.toList()..sort(),
    'serverName': serverName,
    if (toolsFetchedAt != null)
      'toolsFetchedAt': toolsFetchedAt!.toIso8601String(),
  };
}

class McpConnectorsConfig {
  const McpConnectorsConfig({this.connectors = const <McpConnector>[]});

  final List<McpConnector> connectors;

  McpConnector? byId(String id) =>
      connectors.where((c) => c.id == id).firstOrNull;

  factory McpConnectorsConfig.fromJson(Map<String, dynamic> json) =>
      McpConnectorsConfig(
        connectors: [
          for (final item in json['connectors'] as List? ?? const [])
            if (item is Map)
              McpConnector.fromJson(Map<String, dynamic>.from(item)),
        ].where((c) => McpToolNaming.isValidConnectorId(c.id)).toList(),
      );

  Map<String, dynamic> toJson() => {
    'connectors': [for (final c in connectors) c.toJson()],
  };
}

/// 连接器插件 id 与发给模型的工具名规则。
///
/// 工具名形如 `mcp__<连接器id>__<工具名>`，满足各家 `^[A-Za-z0-9_-]{1,64}$`
/// 约束，并能从工具名反查所属连接器（用于角色关闭时成对移除历史调用）。
class McpToolNaming {
  static const pluginIdPrefix = 'mcp:';
  static const _toolPrefix = 'mcp__';
  static const _maxToolNameLength = 64;
  static final _connectorIdPattern = RegExp(r'^[a-z0-9]{1,16}$');

  static String pluginIdOf(String connectorId) => '$pluginIdPrefix$connectorId';

  static bool isConnectorPluginId(String pluginId) =>
      pluginId.startsWith(pluginIdPrefix);

  static String? connectorIdOfPlugin(String pluginId) =>
      isConnectorPluginId(pluginId)
      ? pluginId.substring(pluginIdPrefix.length)
      : null;

  static bool isValidConnectorId(String id) => _connectorIdPattern.hasMatch(id);

  static String toolName(String connectorId, String serverToolName) {
    final prefix = '$_toolPrefix${connectorId}__';
    final safe = serverToolName.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final full = '$prefix$safe';
    if (full.length <= _maxToolNameLength) return full;
    final hash = _fnv1a(serverToolName).toRadixString(36).padLeft(7, '0');
    final keep = _maxToolNameLength - prefix.length - hash.length - 1;
    return '$prefix${safe.substring(0, keep)}_$hash';
  }

  /// 工具名属于某个连接器时返回其 id，否则返回 null。
  static String? connectorIdOfTool(String toolName) {
    if (!toolName.startsWith(_toolPrefix)) return null;
    final rest = toolName.substring(_toolPrefix.length);
    final end = rest.indexOf('__');
    if (end <= 0) return null;
    final id = rest.substring(0, end);
    return isValidConnectorId(id) ? id : null;
  }

  static int _fnv1a(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash;
  }
}

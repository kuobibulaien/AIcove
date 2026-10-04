/// 去掉请求体里的模型内置搜索参数。
///
/// 联网搜索插件开启“关闭模型内置搜索”时，在请求体组装完成（含渠道额外参数）
/// 后调用，保证本轮只通过插件的 `web_search` 工具联网。普通函数工具不受影响。
library;

/// 顶层内置搜索开关字段：OpenAI 搜索模型、xAI 实时搜索、通义/Kimi 等。
const _builtinSearchTopLevelKeys = <String>{
  'web_search_options',
  'search_parameters',
  'enable_search',
  'search_options',
  'enable_web_search',
};

/// Gemini 内置工具键（同一条 tools 元素里只放内置工具）。
const _geminiBuiltinToolKeys = <String>{
  'googleSearch',
  'google_search',
  'googleSearchRetrieval',
  'google_search_retrieval',
  'urlContext',
  'url_context',
};

/// 返回被移除的项目，供请求诊断记录；没有内置搜索时返回空表且不改动请求体。
List<String> stripBuiltinWebSearch(Map<String, dynamic> body) {
  final removed = <String>[];
  for (final key in _builtinSearchTopLevelKeys) {
    if (body.remove(key) != null) removed.add(key);
  }

  final extra = body['extra_body'];
  if (extra is Map) {
    for (final key in _builtinSearchTopLevelKeys) {
      if (extra.remove(key) != null) removed.add('extra_body.$key');
    }
  }

  // OpenRouter 网页插件：plugins: [{"id": "web"}]
  final plugins = body['plugins'];
  if (plugins is List) {
    final kept = plugins
        .where((p) => !(p is Map && p['id'] == 'web'))
        .toList();
    if (kept.length != plugins.length) {
      removed.add('plugins.web');
      if (kept.isEmpty) {
        body.remove('plugins');
      } else {
        body['plugins'] = kept;
      }
    }
  }

  final tools = body['tools'];
  if (tools is List) {
    final kept = <Object?>[];
    for (final tool in tools) {
      final label = _builtinSearchToolLabel(tool);
      if (label == null) {
        kept.add(tool);
      } else {
        removed.add('tools.$label');
      }
    }
    if (kept.length != tools.length) {
      if (kept.isEmpty) {
        body.remove('tools');
        body.remove('tool_choice');
      } else {
        body['tools'] = kept;
      }
    }
  }
  return removed;
}

/// 识别一条内置搜索工具，返回用于诊断的名称；普通函数工具返回 null。
String? _builtinSearchToolLabel(Object? tool) {
  if (tool is! Map) return null;
  final type = tool['type'];
  if (type is String) {
    final normalized = type.toLowerCase();
    // OpenAI web_search / web_search_preview、Claude web_search_20250305 /
    // web_fetch_*、xAI web_search / x_search、智谱 {"type": "web_search"}。
    if (normalized.startsWith('web_search') ||
        normalized.startsWith('web_fetch') ||
        normalized == 'x_search') {
      return normalized;
    }
    // Kimi：{"type": "builtin_function", "function": {"name": "$web_search"}}
    if (normalized == 'builtin_function') {
      final function = tool['function'];
      final name = function is Map ? function['name'] : null;
      if (name == r'$web_search') return 'builtin_function.$name';
    }
    return null;
  }
  final keys = tool.keys.whereType<String>().toSet();
  if (keys.isNotEmpty && keys.every(_geminiBuiltinToolKeys.contains)) {
    return keys.join('+');
  }
  return null;
}

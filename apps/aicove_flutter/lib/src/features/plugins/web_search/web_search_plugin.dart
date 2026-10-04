import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../core/app_logger.dart';
import '../../content_tags/domain/content_tag_registry.dart';
import '../domain/index.dart';
import 'web_search_config.dart';
import 'web_search_service.dart';

/// 联网搜索插件：向聊天模型提供 `web_search` 与 `web_fetch` 两个工具。
///
/// 只走 Function Calling，没有可用供应商或模型不支持工具时不生效；
/// 多家供应商由 [WebSearchService] 按顺序调用与失败切换，插件不关心具体厂商。
class WebSearchPlugin extends BasePlugin {
  static const String pluginId = 'web_search';
  static const String searchToolName = 'web_search';
  static const String fetchToolName = 'web_fetch';
  static const int maxFetchUrls = 5;

  /// 插件拥有的工具（ADR0044）：关闭时历史里的调用与结果成对移出请求副本。
  static const contentTags = StaticContentTagProvider(
    providerId: pluginId,
    tagSpecs: [],
    toolNames: {searchToolName, fetchToolName},
  );

  static const _metadata = PluginMetadata(
    id: pluginId,
    name: '联网搜索',
    description: '让 AI 通过搜索供应商查询网页和最新信息',
    version: '1.0.0',
    author: 'AIcove Team',
    icon: Icons.travel_explore,
  );

  WebSearchPlugin(this._config, {http.Client? client})
    : _client = client,
      super(metadata: _metadata);

  WebSearchConfig _config;
  final http.Client? _client;

  @override
  bool get enabled => _config.isConfigured;

  /// 本插件生效时是否要求去掉模型内置搜索参数。
  bool get replacesModelBuiltinSearch =>
      enabled && _config.replaceModelBuiltinSearch;

  WebSearchService get _service => WebSearchService(_config, client: _client);

  @override
  List<AITool> getTools() {
    if (!enabled) return const [];
    return [
      AITool(
        name: searchToolName,
        description:
            '联网搜索网页。需要最新信息、实时事件、你不确定的事实或用户要求查资料时调用。'
            '返回若干条结果（标题、链接、发布时间、正文摘录）。'
            'query 用一句完整的自然语言描述想找的内容，不要只堆关键词。',
        parameters: {
          'query': const ToolParameter(
            type: 'string',
            description: '搜索内容，用自然语言描述理想的网页',
            required: true,
          ),
          'num_results': ToolParameter(
            type: 'integer',
            description:
                '返回条数，${WebSearchConfig.minResults}~${WebSearchConfig.maxResults}，'
                '默认 ${_config.numResults}',
          ),
        },
        handler: _handleSearch,
      ),
      AITool(
        name: fetchToolName,
        description:
            '读取指定网页的正文。搜索结果摘录不够、或用户给了链接需要阅读时调用。'
            '一次最多 $maxFetchUrls 个链接。',
        parameters: {
          'urls': const ToolParameter(
            type: 'array',
            description: '要读取的网页链接列表（http/https）',
            required: true,
            items: {'type': 'string'},
          ),
        },
        handler: _handleFetch,
      ),
    ];
  }

  Future<String?> _handleSearch(Map<String, dynamic> args) async {
    final query = (args['query'] ?? '').toString().trim();
    if (query.isEmpty) return _error('query 不能为空');
    try {
      final outcome = await _service.search(
        query,
        numResults: (args['num_results'] as num?)?.toInt(),
      );
      return jsonEncode({
        'query': query,
        'source': outcome.source,
        'results': [for (final r in outcome.results) r.toJson()],
      });
    } catch (e) {
      AppLogger.warning('WebSearchPlugin', '联网搜索失败', metadata: {
        'error': e.toString(),
      });
      return _error('搜索失败：$e');
    }
  }

  Future<String?> _handleFetch(Map<String, dynamic> args) async {
    final raw = args['urls'];
    final candidates = raw is List
        ? raw.map((e) => e.toString())
        : raw is String
        ? [raw]
        : const <String>[];
    final urls = [
      for (final url in candidates.map((e) => e.trim()))
        if (_isHttpUrl(url)) url,
    ].take(maxFetchUrls).toList();
    if (urls.isEmpty) return _error('urls 中没有有效的 http/https 链接');
    try {
      final outcome = await _service.fetch(urls);
      return jsonEncode({
        'source': outcome.source,
        'results': [for (final r in outcome.results) r.toJson()],
      });
    } catch (e) {
      AppLogger.warning('WebSearchPlugin', '读取网页失败', metadata: {
        'error': e.toString(),
      });
      return _error('读取网页失败：$e');
    }
  }

  static bool _isHttpUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  static String _error(String message) => jsonEncode({'error': message});

  @override
  Future<String?> getSystemPrompt({
    String? userMessage,
    bool supportsToolCalling = false,
  }) async => null;

  @override
  Future<PluginProcessResult> processResponse(String text) async =>
      PluginProcessResult(processedText: text, events: const []);

  @override
  void updateConfig(Map<String, dynamic> config) {
    _config = WebSearchConfig.fromJson(config);
  }

  @override
  Map<String, dynamic> getConfig() => _config.toJson();
}

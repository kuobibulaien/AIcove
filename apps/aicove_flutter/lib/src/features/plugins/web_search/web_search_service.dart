import 'package:http/http.dart' as http;

import '../../../core/app_logger.dart';
import 'web_search_adapter.dart';
import 'web_search_config.dart';

/// 一次搜索或读取的结果，附带实际提供结果的来源。
class WebSearchOutcome {
  final String source;
  final List<WebSearchResult> results;

  const WebSearchOutcome({required this.source, required this.results});
}

/// 按供应商列表顺序调用，前一家失败自动换下一家。
class WebSearchService {
  WebSearchService(this._config, {http.Client? client}) : _client = client;

  final WebSearchConfig _config;
  final http.Client? _client;

  Future<WebSearchOutcome> search(String query, {int? numResults}) async {
    final providers = _config.usableProviders;
    if (providers.isEmpty) {
      throw const WebSearchException('没有可用的搜索供应商');
    }
    final count = (numResults ?? _config.numResults).clamp(
      WebSearchConfig.minResults,
      WebSearchConfig.maxResults,
    );
    final errors = <String>[];
    for (final provider in providers) {
      try {
        final results = await createWebSearchAdapter(
          provider,
          client: _client,
        ).search(
          query,
          numResults: count,
          maxCharacters: _config.maxCharactersPerResult,
        );
        return WebSearchOutcome(
          source: provider.displayName,
          results: results,
        );
      } catch (e) {
        errors.add('${provider.displayName}：$e');
        AppLogger.warning('WebSearchService', '搜索供应商失败，尝试下一家', metadata: {
          'provider': provider.type.id,
          'error': e.toString(),
        });
      }
    }
    throw WebSearchException('全部搜索供应商失败：${errors.join('；')}');
  }

  /// 依次尝试带正文接口的供应商，都不行时直接抓取网页。
  Future<WebSearchOutcome> fetch(List<String> urls) async {
    final maxCharacters = _config.maxCharactersPerResult;
    for (final provider in _config.usableProviders) {
      if (!provider.type.supportsFetch) continue;
      try {
        final results = await createWebSearchAdapter(
          provider,
          client: _client,
        ).fetch(urls, maxCharacters: maxCharacters);
        if (results.isNotEmpty) {
          return WebSearchOutcome(
            source: provider.displayName,
            results: results,
          );
        }
      } catch (e) {
        AppLogger.warning('WebSearchService', '读取网页失败，尝试下一家', metadata: {
          'provider': provider.type.id,
          'error': e.toString(),
        });
      }
    }
    final results = await DirectWebPageFetcher(
      client: _client,
    ).fetch(urls, maxCharacters: maxCharacters);
    return WebSearchOutcome(source: '直接读取', results: results);
  }
}

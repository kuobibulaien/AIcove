import 'dart:convert';

import 'package:http/http.dart' as http;

import 'web_search_config.dart';

/// 一条搜索结果或一个网页的正文。
class WebSearchResult {
  final String title;
  final String url;
  final String? publishedDate;
  final String? author;
  final String text;

  const WebSearchResult({
    required this.title,
    required this.url,
    this.publishedDate,
    this.author,
    this.text = '',
  });

  Map<String, dynamic> toJson() => {
    'title': title,
    'url': url,
    if (publishedDate != null) 'publishedDate': publishedDate,
    if (author != null) 'author': author,
    if (text.isNotEmpty) 'text': text,
  };
}

class WebSearchException implements Exception {
  final String message;
  final int? statusCode;

  const WebSearchException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

/// 搜索供应商适配器：插件只依赖这个接口，每家供应商一个实现。
abstract class WebSearchAdapter {
  Future<List<WebSearchResult>> search(
    String query, {
    required int numResults,
    required int maxCharacters,
  });

  /// 读取网页正文；供应商没有正文接口时抛 [UnsupportedError]。
  Future<List<WebSearchResult>> fetch(
    List<String> urls, {
    required int maxCharacters,
  }) => throw UnsupportedError('该供应商不支持读取网页');
}

WebSearchAdapter createWebSearchAdapter(
  WebSearchProviderEntry entry, {
  http.Client? client,
}) {
  final http = WebSearchHttp(
    label: entry.type.label,
    baseUrl: entry.effectiveBaseUrl,
    client: client,
  );
  final key = entry.apiKey.trim();
  return switch (entry.type) {
    WebSearchProviderType.exa => ExaWebSearchAdapter(http, key),
    WebSearchProviderType.tavily => TavilyWebSearchAdapter(http, key),
    WebSearchProviderType.brave => BraveWebSearchAdapter(http, key),
    WebSearchProviderType.bocha => BochaWebSearchAdapter(http, key),
    WebSearchProviderType.zhipu => ZhipuWebSearchAdapter(http, key),
    WebSearchProviderType.perplexity => PerplexityWebSearchAdapter(http, key),
    WebSearchProviderType.jina => JinaWebSearchAdapter(http, key),
    WebSearchProviderType.firecrawl => FirecrawlWebSearchAdapter(http, key),
    WebSearchProviderType.serper => SerperWebSearchAdapter(http, key),
    WebSearchProviderType.searxng => SearxngWebSearchAdapter(http, key),
  };
}

/// Exa：`POST /search` 搜索并带回正文，`POST /contents` 读取网页。
/// https://exa.ai/docs/reference/search
class ExaWebSearchAdapter extends WebSearchAdapter {
  ExaWebSearchAdapter(this._http, this._key);
  final WebSearchHttp _http;
  final String _key;

  Map<String, String> get _headers => {'x-api-key': _key};

  @override
  Future<List<WebSearchResult>> search(
    String query, {
    required int numResults,
    required int maxCharacters,
  }) async {
    final data = await _http.postJson('/search', _headers, {
      'query': query,
      'type': 'auto',
      'numResults': numResults,
      'contents': {
        'text': {'maxCharacters': maxCharacters},
      },
    });
    return _results(data['results'], maxCharacters, text: 'text');
  }

  @override
  Future<List<WebSearchResult>> fetch(
    List<String> urls, {
    required int maxCharacters,
  }) async {
    final data = await _http.postJson('/contents', _headers, {
      'urls': urls,
      'text': {'maxCharacters': maxCharacters},
    });
    return _results(data['results'], maxCharacters, text: 'text');
  }
}

/// Tavily：`POST /search`、`POST /extract`，Bearer 鉴权。
/// https://docs.tavily.com/documentation/api-reference/endpoint/search
class TavilyWebSearchAdapter extends WebSearchAdapter {
  TavilyWebSearchAdapter(this._http, this._key);
  final WebSearchHttp _http;
  final String _key;

  Map<String, String> get _headers => {'Authorization': 'Bearer $_key'};

  @override
  Future<List<WebSearchResult>> search(
    String query, {
    required int numResults,
    required int maxCharacters,
  }) async {
    final data = await _http.postJson('/search', _headers, {
      'query': query,
      'max_results': numResults,
      'search_depth': 'basic',
    });
    return _results(
      data['results'],
      maxCharacters,
      text: 'content',
      date: 'published_date',
    );
  }

  @override
  Future<List<WebSearchResult>> fetch(
    List<String> urls, {
    required int maxCharacters,
  }) async {
    final data = await _http.postJson('/extract', _headers, {'urls': urls});
    return _results(data['results'], maxCharacters, text: 'raw_content');
  }
}

/// Brave Search：`GET /res/v1/web/search`，`X-Subscription-Token` 鉴权。
class BraveWebSearchAdapter extends WebSearchAdapter {
  BraveWebSearchAdapter(this._http, this._key);
  final WebSearchHttp _http;
  final String _key;

  @override
  Future<List<WebSearchResult>> search(
    String query, {
    required int numResults,
    required int maxCharacters,
  }) async {
    final data = await _http.getJson(
      '/res/v1/web/search',
      {'X-Subscription-Token': _key},
      {'q': query, 'count': '$numResults', 'extra_snippets': 'true'},
    );
    final web = data['web'];
    final items = web is Map ? web['results'] : null;
    return [
      for (final item in _maps(items))
        WebSearchResult(
          title: _str(item['title']),
          url: _str(item['url']),
          publishedDate: _opt(item['page_age'] ?? item['age']),
          text: _truncate(
            [
              _str(item['description']),
              ..._list(item['extra_snippets']).map(_str),
            ].where((s) => s.isNotEmpty).join('\n'),
            maxCharacters,
          ),
        ),
    ];
  }
}

/// 博查：`POST /v1/web-search`，返回格式兼容 Bing（`webPages.value`）。
class BochaWebSearchAdapter extends WebSearchAdapter {
  BochaWebSearchAdapter(this._http, this._key);
  final WebSearchHttp _http;
  final String _key;

  @override
  Future<List<WebSearchResult>> search(
    String query, {
    required int numResults,
    required int maxCharacters,
  }) async {
    final raw = await _http.postJson(
      '/v1/web-search',
      {'Authorization': 'Bearer $_key'},
      {'query': query, 'count': numResults, 'summary': true},
    );
    final data = raw['data'] is Map ? raw['data'] as Map : raw;
    final pages = data['webPages'];
    return [
      for (final item in _maps(pages is Map ? pages['value'] : null))
        WebSearchResult(
          title: _str(item['name']),
          url: _str(item['url']),
          publishedDate: _opt(item['datePublished']),
          author: _opt(item['siteName']),
          text: _truncate(
            _str(item['summary']).isNotEmpty
                ? _str(item['summary'])
                : _str(item['snippet']),
            maxCharacters,
          ),
        ),
    ];
  }
}

/// 智谱：`POST /paas/v4/web_search`，Bearer 鉴权。
/// https://docs.bigmodel.cn/api-reference/工具-api/网络搜索
class ZhipuWebSearchAdapter extends WebSearchAdapter {
  ZhipuWebSearchAdapter(this._http, this._key);
  final WebSearchHttp _http;
  final String _key;

  @override
  Future<List<WebSearchResult>> search(
    String query, {
    required int numResults,
    required int maxCharacters,
  }) async {
    final data = await _http.postJson(
      '/paas/v4/web_search',
      {'Authorization': 'Bearer $_key'},
      {
        // 官方建议 query 不超过 70 个字符。
        'search_query': query.length > 70 ? query.substring(0, 70) : query,
        'search_engine': 'search_std',
        'search_intent': false,
        'count': numResults,
      },
    );
    return [
      for (final item in _maps(data['search_result']))
        WebSearchResult(
          title: _str(item['title']),
          url: _str(item['link']),
          publishedDate: _opt(item['publish_date']),
          author: _opt(item['media']),
          text: _truncate(_str(item['content']), maxCharacters),
        ),
    ];
  }
}

/// Perplexity Search API：`POST /search`，Bearer 鉴权。
/// https://docs.perplexity.ai/api-reference/search-post
class PerplexityWebSearchAdapter extends WebSearchAdapter {
  PerplexityWebSearchAdapter(this._http, this._key);
  final WebSearchHttp _http;
  final String _key;

  @override
  Future<List<WebSearchResult>> search(
    String query, {
    required int numResults,
    required int maxCharacters,
  }) async {
    final data = await _http.postJson(
      '/search',
      {'Authorization': 'Bearer $_key'},
      {'query': query, 'max_results': numResults},
    );
    return _results(data['results'], maxCharacters, text: 'snippet');
  }
}

/// Jina：搜索 `GET s.jina.ai/?q=`，读取网页 `GET r.jina.ai/<url>`。
class JinaWebSearchAdapter extends WebSearchAdapter {
  JinaWebSearchAdapter(this._http, this._key);
  final WebSearchHttp _http;
  final String _key;

  static const readerBaseUrl = 'https://r.jina.ai';

  Map<String, String> get _headers => {
    if (_key.isNotEmpty) 'Authorization': 'Bearer $_key',
  };

  @override
  Future<List<WebSearchResult>> search(
    String query, {
    required int numResults,
    required int maxCharacters,
  }) async {
    final data = await _http.getJson('/', _headers, {'q': query});
    return _results(
      data['data'],
      maxCharacters,
      text: 'content',
      fallbackText: 'description',
      date: 'date',
    ).take(numResults).toList();
  }

  @override
  Future<List<WebSearchResult>> fetch(
    List<String> urls, {
    required int maxCharacters,
  }) async {
    final reader = _http.withBaseUrl(readerBaseUrl);
    final pages = await Future.wait([
      for (final url in urls) reader.getJson('/$url', _headers, const {}),
    ]);
    return [
      for (final page in pages)
        ..._results([page['data']], maxCharacters, text: 'content'),
    ];
  }
}

/// Firecrawl v2：`POST /v2/search`、`POST /v2/scrape`，Bearer 鉴权。
/// https://docs.firecrawl.dev/api-reference/endpoint/search
class FirecrawlWebSearchAdapter extends WebSearchAdapter {
  FirecrawlWebSearchAdapter(this._http, this._key);
  final WebSearchHttp _http;
  final String _key;

  Map<String, String> get _headers => {'Authorization': 'Bearer $_key'};

  @override
  Future<List<WebSearchResult>> search(
    String query, {
    required int numResults,
    required int maxCharacters,
  }) async {
    final raw = await _http.postJson('/v2/search', _headers, {
      'query': query,
      'limit': numResults,
    });
    final data = raw['data'];
    final items = data is Map ? data['web'] : data;
    return _results(items, maxCharacters, text: 'description');
  }

  @override
  Future<List<WebSearchResult>> fetch(
    List<String> urls, {
    required int maxCharacters,
  }) async {
    final pages = await Future.wait([
      for (final url in urls)
        _http.postJson('/v2/scrape', _headers, {
          'url': url,
          'formats': ['markdown'],
        }),
    ]);
    return [
      for (var i = 0; i < pages.length; i++)
        if (pages[i]['data'] case final Map data)
          WebSearchResult(
            title: _str((data['metadata'] as Map?)?['title']),
            url: urls[i],
            text: _truncate(_str(data['markdown']), maxCharacters),
          ),
    ];
  }
}

/// Serper（Google 结果）：`POST /search`，`X-API-KEY` 鉴权。
class SerperWebSearchAdapter extends WebSearchAdapter {
  SerperWebSearchAdapter(this._http, this._key);
  final WebSearchHttp _http;
  final String _key;

  @override
  Future<List<WebSearchResult>> search(
    String query, {
    required int numResults,
    required int maxCharacters,
  }) async {
    final data = await _http.postJson(
      '/search',
      {'X-API-KEY': _key},
      {'q': query, 'num': numResults},
    );
    return [
      for (final item in _maps(data['organic']))
        WebSearchResult(
          title: _str(item['title']),
          url: _str(item['link']),
          publishedDate: _opt(item['date']),
          text: _truncate(_str(item['snippet']), maxCharacters),
        ),
    ];
  }
}

/// SearXNG 自建实例：`GET /search?format=json`（实例需开启 JSON 输出）。
class SearxngWebSearchAdapter extends WebSearchAdapter {
  SearxngWebSearchAdapter(this._http, this._key);
  final WebSearchHttp _http;
  final String _key;

  @override
  Future<List<WebSearchResult>> search(
    String query, {
    required int numResults,
    required int maxCharacters,
  }) async {
    final data = await _http.getJson(
      '/search',
      {if (_key.isNotEmpty) 'Authorization': 'Bearer $_key'},
      {'q': query, 'format': 'json'},
    );
    return _results(
      data['results'],
      maxCharacters,
      text: 'content',
    ).take(numResults).toList();
  }
}

/// 不依赖供应商的网页读取兜底：直接下载网页并粗略提取正文。
class DirectWebPageFetcher {
  DirectWebPageFetcher({http.Client? client}) : _client = client;
  final http.Client? _client;

  Future<List<WebSearchResult>> fetch(
    List<String> urls, {
    required int maxCharacters,
  }) async {
    final http = WebSearchHttp(label: '网页', baseUrl: '', client: _client);
    return Future.wait([
      for (final url in urls)
        http.getText(url).then((html) {
          final title = RegExp(
            r'<title[^>]*>([\s\S]*?)</title>',
            caseSensitive: false,
          ).firstMatch(html)?.group(1);
          return WebSearchResult(
            title: _decodeEntities(title ?? '').trim(),
            url: url,
            text: _truncate(htmlToText(html), maxCharacters),
          );
        }),
    ]);
  }

  static String htmlToText(String html) {
    var text = html.replaceAll(
      RegExp(
        r'<(script|style|noscript|svg|head)[^>]*>[\s\S]*?</\1>',
        caseSensitive: false,
      ),
      ' ',
    );
    text = text.replaceAll(
      RegExp(r'<(br|/p|/div|/li|/h[1-6]|/tr)[^>]*>', caseSensitive: false),
      '\n',
    );
    text = _decodeEntities(text.replaceAll(RegExp(r'<[^>]+>'), ' '));
    return text
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((line) => line.isNotEmpty)
        .join('\n');
  }

  static String _decodeEntities(String text) => text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');
}

/// 各适配器共用的 HTTP 调用与错误整理。
class WebSearchHttp {
  WebSearchHttp({required this.label, required this.baseUrl, this.client});

  final String label;
  final String baseUrl;
  final http.Client? client;
  static const timeout = Duration(seconds: 30);

  WebSearchHttp withBaseUrl(String base) =>
      WebSearchHttp(label: label, baseUrl: base, client: client);

  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, String> headers,
    Map<String, dynamic> body,
  ) => _send(
    (c) => c.post(
      Uri.parse('$baseUrl$path'),
      headers: {
        ...headers,
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode(body),
    ),
  ).then(_decodeJson);

  Future<Map<String, dynamic>> getJson(
    String path,
    Map<String, String> headers,
    Map<String, String> query,
  ) {
    final uri = Uri.parse('$baseUrl$path');
    return _send(
      (c) => c.get(
        query.isEmpty ? uri : uri.replace(queryParameters: query),
        headers: {...headers, 'Accept': 'application/json'},
      ),
    ).then(_decodeJson);
  }

  Future<String> getText(String url) => _send(
    (c) => c.get(
      Uri.parse(url),
      headers: const {
        'User-Agent': 'Mozilla/5.0 (compatible; AIcove/1.0)',
        'Accept': 'text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5',
      },
    ),
  );

  Future<String> _send(
    Future<http.Response> Function(http.Client client) request,
  ) async {
    final c = client ?? http.Client();
    try {
      final response = await request(c).timeout(timeout);
      final text = utf8.decode(response.bodyBytes, allowMalformed: true);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw WebSearchException(
          '$label 请求失败（HTTP ${response.statusCode}）：${_errorMessage(text)}',
          statusCode: response.statusCode,
        );
      }
      return text;
    } finally {
      if (client == null) c.close();
    }
  }

  Map<String, dynamic> _decodeJson(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw WebSearchException('$label 返回的不是 JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw WebSearchException('$label 返回格式无法识别');
    }
    return decoded;
  }

  static String _errorMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'] ?? decoded['message'] ?? decoded['msg'];
        if (error is Map && error['message'] != null) {
          return error['message'].toString();
        }
        if (error != null) return error.toString();
      }
    } on FormatException {
      // 非 JSON 错误体，直接截断返回。
    }
    return body.length > 200 ? '${body.substring(0, 200)}…' : body;
  }
}

List<WebSearchResult> _results(
  Object? items,
  int maxCharacters, {
  required String text,
  String? fallbackText,
  String date = 'publishedDate',
}) {
  return [
    for (final item in _maps(items))
      WebSearchResult(
        title: _str(item['title']),
        url: _str(item['url'] ?? item['id']),
        publishedDate: _opt(item[date] ?? item['date']),
        author: _opt(item['author']),
        text: _truncate(
          _str(item[text]).isNotEmpty || fallbackText == null
              ? _str(item[text])
              : _str(item[fallbackText]),
          maxCharacters,
        ),
      ),
  ];
}

Iterable<Map> _maps(Object? value) =>
    value is List ? value.whereType<Map>() : const <Map>[];

List<Object?> _list(Object? value) => value is List ? value : const [];

String _str(Object? value) => value?.toString() ?? '';

String? _opt(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

String _truncate(String text, int maxCharacters) {
  final trimmed = text.trim();
  return trimmed.length > maxCharacters
      ? '${trimmed.substring(0, maxCharacters)}…'
      : trimmed;
}

import 'dart:convert';

import 'package:aicove_flutter/src/features/chat/services/chat_plugin_context_policy.dart';
import 'package:aicove_flutter/src/features/plugins/web_search/web_search_adapter.dart';
import 'package:aicove_flutter/src/features/plugins/web_search/web_search_config.dart';
import 'package:aicove_flutter/src/features/plugins/web_search/web_search_plugin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

WebSearchProviderEntry _entry(
  WebSearchProviderType type, {
  String id = '',
  String key = 'k',
  String baseUrl = '',
  bool enabled = true,
}) => WebSearchProviderEntry(
  id: id.isEmpty ? type.id : id,
  type: type,
  apiKey: key,
  baseUrl: baseUrl,
  enabled: enabled,
);

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Future<Map<String, dynamic>> _call(
  WebSearchPlugin plugin,
  String tool,
  Map<String, dynamic> args,
) async {
  final handler = plugin.getTools().firstWhere((t) => t.name == tool).handler;
  return jsonDecode((await handler(args))!) as Map<String, dynamic>;
}

void main() {
  test('没有可用供应商时插件不生效、不提供工具', () {
    for (final config in [
      const WebSearchConfig(),
      WebSearchConfig(
        providers: [
          _entry(WebSearchProviderType.exa, key: ''),
          _entry(WebSearchProviderType.tavily, enabled: false),
          _entry(WebSearchProviderType.searxng, key: ''),
        ],
      ),
    ]) {
      final plugin = WebSearchPlugin(config);
      expect(plugin.enabled, isFalse);
      expect(plugin.getTools(), isEmpty);
    }
  });

  test('SearXNG 不需要密钥，填了地址即可用', () {
    final entry = _entry(
      WebSearchProviderType.searxng,
      key: '',
      baseUrl: 'https://searx.test/',
    );
    expect(entry.isUsable, isTrue);
    expect(entry.effectiveBaseUrl, 'https://searx.test');
  });

  test('web_search 按 Exa 协议请求并整理结果', () async {
    late http.Request captured;
    final client = MockClient((request) async {
      captured = request;
      return _json({
        'results': [
          {
            'title': '标题',
            'url': 'https://example.com/a',
            'publishedDate': '2026-10-01T00:00:00.000Z',
            'author': '',
            'text': 'x' * 300,
          },
        ],
      });
    });
    final plugin = WebSearchPlugin(
      WebSearchConfig(
        providers: [
          _entry(
            WebSearchProviderType.exa,
            key: 'key-123',
            baseUrl: 'https://proxy.test/',
          ),
        ],
        maxCharactersPerResult: 200,
      ),
      client: client,
    );

    final result = await _call(plugin, 'web_search', {
      'query': '今天的新闻',
      'num_results': 99,
    });

    expect(captured.url.toString(), 'https://proxy.test/search');
    expect(captured.headers['x-api-key'], 'key-123');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['numResults'], WebSearchConfig.maxResults);
    expect(body['contents'], {
      'text': {'maxCharacters': 200},
    });
    expect(result['source'], 'Exa');
    final first = (result['results'] as List).single as Map<String, dynamic>;
    expect(first['url'], 'https://example.com/a');
    expect(first.containsKey('author'), isFalse);
    expect((first['text'] as String).length, 201);
  });

  test('前一家失败自动换下一家，全部失败时汇总原因', () async {
    final hosts = <String>[];
    final client = MockClient((request) async {
      hosts.add(request.url.host);
      if (request.url.host == 'api.exa.ai') {
        return _json({'error': 'Invalid API key'}, 401);
      }
      return _json({
        'results': [
          {'title': 't', 'url': 'https://b.test', 'content': '内容'},
        ],
      });
    });
    final plugin = WebSearchPlugin(
      WebSearchConfig(
        providers: [
          _entry(WebSearchProviderType.exa),
          _entry(WebSearchProviderType.brave, enabled: false),
          _entry(WebSearchProviderType.tavily),
        ],
      ),
      client: client,
    );

    final result = await _call(plugin, 'web_search', {'query': 'q'});
    expect(hosts, ['api.exa.ai', 'api.tavily.com']);
    expect(result['source'], 'Tavily');

    final failing = WebSearchPlugin(
      WebSearchConfig(providers: [_entry(WebSearchProviderType.exa)]),
      client: MockClient((_) async => _json({'error': 'Invalid API key'}, 401)),
    );
    final error = (await _call(failing, 'web_search', {'query': 'q'}))['error'];
    expect(error, contains('401'));
    expect(error, contains('Invalid API key'));
  });

  group('各供应商请求与解析', () {
    final cases = <WebSearchProviderType, (String, Object, String)>{
      WebSearchProviderType.tavily: (
        'POST https://api.tavily.com/search',
        {
          'results': [
            {'title': 'T', 'url': 'https://r.test', 'content': '正文'},
          ],
        },
        'Authorization',
      ),
      WebSearchProviderType.brave: (
        'GET https://api.search.brave.com/res/v1/web/search',
        {
          'web': {
            'results': [
              {
                'title': 'T',
                'url': 'https://r.test',
                'description': '正文',
                'extra_snippets': ['补充'],
              },
            ],
          },
        },
        'X-Subscription-Token',
      ),
      WebSearchProviderType.bocha: (
        'POST https://api.bochaai.com/v1/web-search',
        {
          'code': 200,
          'data': {
            'webPages': {
              'value': [
                {'name': 'T', 'url': 'https://r.test', 'summary': '正文'},
              ],
            },
          },
        },
        'Authorization',
      ),
      WebSearchProviderType.zhipu: (
        'POST https://open.bigmodel.cn/api/paas/v4/web_search',
        {
          'search_result': [
            {'title': 'T', 'link': 'https://r.test', 'content': '正文'},
          ],
        },
        'Authorization',
      ),
      WebSearchProviderType.perplexity: (
        'POST https://api.perplexity.ai/search',
        {
          'results': [
            {'title': 'T', 'url': 'https://r.test', 'snippet': '正文'},
          ],
        },
        'Authorization',
      ),
      WebSearchProviderType.jina: (
        'GET https://s.jina.ai/',
        {
          'code': 200,
          'data': [
            {'title': 'T', 'url': 'https://r.test', 'content': '正文'},
          ],
        },
        'Authorization',
      ),
      WebSearchProviderType.firecrawl: (
        'POST https://api.firecrawl.dev/v2/search',
        {
          'success': true,
          'data': {
            'web': [
              {'title': 'T', 'url': 'https://r.test', 'description': '正文'},
            ],
          },
        },
        'Authorization',
      ),
      WebSearchProviderType.serper: (
        'POST https://google.serper.dev/search',
        {
          'organic': [
            {'title': 'T', 'link': 'https://r.test', 'snippet': '正文'},
          ],
        },
        'X-API-KEY',
      ),
      WebSearchProviderType.searxng: (
        'GET https://searx.test/search',
        {
          'results': [
            {'title': 'T', 'url': 'https://r.test', 'content': '正文'},
          ],
        },
        '',
      ),
    };

    for (final MapEntry(key: type, value: (endpoint, response, authHeader))
        in cases.entries) {
      test(type.label, () async {
        late http.Request captured;
        final client = MockClient((request) async {
          captured = request;
          return _json(response);
        });
        final entry = _entry(
          type,
          key: type == WebSearchProviderType.searxng ? '' : 'secret',
          baseUrl: type == WebSearchProviderType.searxng
              ? 'https://searx.test'
              : '',
        );

        final results = await createWebSearchAdapter(
          entry,
          client: client,
        ).search('天气', numResults: 3, maxCharacters: 500);

        final uri = captured.url.replace(query: '');
        expect(
          '${captured.method} ${uri.toString().replaceAll('?', '')}',
          endpoint,
        );
        if (authHeader.isNotEmpty) {
          expect(captured.headers[authHeader], contains('secret'));
        }
        expect(results.single.title, 'T');
        expect(results.single.url, 'https://r.test');
        expect(results.single.text, startsWith('正文'));
      });
    }
  });

  test('web_fetch 优先用带正文接口的供应商，并过滤非 http 链接', () async {
    late http.Request captured;
    final client = MockClient((request) async {
      captured = request;
      return _json({
        'results': [
          {'url': 'https://a.test/x', 'raw_content': '正文'},
        ],
      });
    });
    final plugin = WebSearchPlugin(
      WebSearchConfig(
        providers: [
          _entry(WebSearchProviderType.brave),
          _entry(WebSearchProviderType.tavily),
        ],
      ),
      client: client,
    );

    final result = await _call(plugin, 'web_fetch', {
      'urls': ['https://a.test/x', 'file:///etc/passwd', 'not a url'],
    });

    expect(captured.url.toString(), 'https://api.tavily.com/extract');
    expect(jsonDecode(captured.body)['urls'], ['https://a.test/x']);
    expect(result['source'], 'Tavily');

    final invalid = await _call(plugin, 'web_fetch', {'urls': 'ftp://x'});
    expect(invalid['error'], isNotNull);
  });

  test('没有供应商能读网页时直接抓取并提取正文', () async {
    final client = MockClient((request) async {
      expect(request.url.toString(), 'https://a.test/page');
      return http.Response(
        '<html><head><title>页面 &amp; 标题</title><style>x{}</style></head>'
        '<body><script>bad()</script><p>第一段</p><div>第二段</div></body></html>',
        200,
        headers: {'content-type': 'text/html; charset=utf-8'},
      );
    });
    final plugin = WebSearchPlugin(
      WebSearchConfig(providers: [_entry(WebSearchProviderType.brave)]),
      client: client,
    );

    final result = await _call(plugin, 'web_fetch', {
      'urls': ['https://a.test/page'],
    });

    expect(result['source'], '直接读取');
    final page = (result['results'] as List).single as Map<String, dynamic>;
    expect(page['title'], '页面 & 标题');
    expect(page['text'], '第一段\n第二段');
  });

  test('数组参数带 items，满足严格 schema 的供应商', () {
    final plugin = WebSearchPlugin(
      WebSearchConfig(providers: [_entry(WebSearchProviderType.exa)]),
    );
    final fetch = plugin.getTools().firstWhere((t) => t.name == 'web_fetch');
    final schema = fetch.toOpenAISchema()['function']['parameters'];
    expect(schema['properties']['urls']['items'], {'type': 'string'});
  });

  test('插件关闭时历史里的搜索调用与结果成对移出请求', () {
    final messages = [
      {
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': 'c1',
            'type': 'function',
            'function': {'name': 'web_search', 'arguments': '{}'},
          },
        ],
      },
      {'role': 'tool', 'tool_call_id': 'c1', 'name': 'web_search', 'content': 'r'},
      {'role': 'user', 'content': '你好'},
    ];
    final inactive = ChatPluginContextPolicy.firstParty(activeProviderIds: {});
    expect(inactive.filterMessages(messages), [
      {'role': 'user', 'content': '你好'},
    ]);
    final active = ChatPluginContextPolicy.firstParty(
      activeProviderIds: {WebSearchPlugin.pluginId},
    );
    expect(active.filterMessages(messages), hasLength(3));
  });

  test('接管内置搜索只在插件生效且开关打开时成立', () {
    final usable = [_entry(WebSearchProviderType.exa)];
    expect(
      WebSearchPlugin(
        WebSearchConfig(providers: usable, replaceModelBuiltinSearch: true),
      ).replacesModelBuiltinSearch,
      isTrue,
    );
    expect(
      WebSearchPlugin(
        WebSearchConfig(providers: usable),
      ).replacesModelBuiltinSearch,
      isFalse,
    );
    expect(
      WebSearchPlugin(
        const WebSearchConfig(replaceModelBuiltinSearch: true),
      ).replacesModelBuiltinSearch,
      isFalse,
    );
  });

  test('配置往返、钳制越界数值、迁移旧版单供应商格式并跳过未知类型', () {
    final config = WebSearchConfig.fromJson({
      'providers': [
        _entry(WebSearchProviderType.zhipu, id: 'a').toJson(),
        {'id': 'b', 'type': 'future_engine', 'apiKey': 'x'},
      ],
      'replaceModelBuiltinSearch': true,
      'numResults': 0,
      'maxCharactersPerResult': 999999,
    });
    expect(config.providers.map((p) => p.id), ['a']);
    expect(config.replaceModelBuiltinSearch, isTrue);
    expect(config.numResults, WebSearchConfig.minResults);
    expect(config.maxCharactersPerResult, WebSearchConfig.maxCharacters);
    expect(
      WebSearchConfig.fromJson(config.toJson()).toJson(),
      config.toJson(),
    );

    final legacy = WebSearchConfig.fromJson({
      'provider': 'exa',
      'apiKey': 'old-key',
      'baseUrl': 'https://proxy.test',
    });
    final migrated = legacy.providers.single;
    expect(migrated.type, WebSearchProviderType.exa);
    expect(migrated.apiKey, 'old-key');
    expect(migrated.baseUrl, 'https://proxy.test');
  });
}

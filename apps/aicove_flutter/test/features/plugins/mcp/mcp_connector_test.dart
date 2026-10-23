import 'package:image/image.dart' as img;
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/agent_plugins/aicove_plugin.dart';
import 'package:aicove_flutter/src/core/services/system_reminder_service.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_request_scope.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_response.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_runtime.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/plugin_prompts.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_request.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:aicove_flutter/src/features/chat/services/chat_plugin_context_builder.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_plugin_context_policy.dart';
import 'package:aicove_flutter/src/features/plugins/mcp/mcp_connector.dart';
import 'package:aicove_flutter/src/features/plugins/mcp/mcp_connector_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/mcp/mcp_http_client.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_manager.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/mcp_connector_detail_page.dart';

final _refProvider = Provider<Ref>((ref) => ref);

/// 最小 Streamable HTTP MCP 服务：校验会话与鉴权，按需用 SSE 回包。
class _FakeMcpServer {
  _FakeMcpServer({this.sse = false});

  final bool sse;
  late final HttpServer _server;
  final requests = <Map<String, dynamic>>[];
  final headersSeen = <Map<String, String>>[];
  String session = 'session-1';
  int initializeCount = 0;

  String get url => 'http://${_server.address.host}:${_server.port}/mcp';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final body = jsonDecode(await utf8.decodeStream(request)) as Map;
    requests.add(Map<String, dynamic>.from(body));
    headersSeen.add({
      'authorization': request.headers.value('authorization') ?? '',
      'session': request.headers.value('mcp-session-id') ?? '',
      'version': request.headers.value('mcp-protocol-version') ?? '',
      'x-extra': request.headers.value('x-extra') ?? '',
    });
    final response = request.response;
    if (request.headers.value('authorization') != 'Bearer secret') {
      response.statusCode = 401;
      await response.close();
      return;
    }
    final method = body['method'];
    if (method != 'initialize' &&
        request.headers.value('mcp-session-id') != session) {
      response.statusCode = 404;
      await response.close();
      return;
    }
    if (!body.containsKey('id')) {
      response.statusCode = 202;
      await response.close();
      return;
    }
    final Object result;
    switch (method) {
      case 'initialize':
        initializeCount++;
        response.headers.set('Mcp-Session-Id', session);
        result = {
          'protocolVersion': '2025-06-18',
          'capabilities': {'tools': {}},
          'serverInfo': {'name': 'weather-server', 'title': '天气服务'},
        };
      case 'tools/list':
        final cursor = (body['params'] as Map?)?['cursor'];
        result = cursor == null
            ? {
                'tools': [
                  {
                    'name': 'get_weather',
                    'description': '查询天气',
                    'inputSchema': {
                      r'$schema': 'http://json-schema.org/draft-07/schema#',
                      'type': 'object',
                      'properties': {
                        'city': {'type': 'string'},
                      },
                      'required': ['city'],
                      'additionalProperties': false,
                    },
                  },
                ],
                'nextCursor': 'page2',
              }
            : {
                'tools': [
                  {'name': 'get.news', 'description': '查新闻'},
                ],
              };
      case 'tools/call':
        final params = body['params'] as Map;
        if (params['name'] == 'get_weather') {
          result = {
            'content': [
              {
                'type': 'text',
                'text': '${(params['arguments'] as Map)['city']}：晴',
              },
              {'type': 'image', 'data': base64Encode(img.encodePng(img.Image(width:1,height:1))), 'mimeType': 'image/png'},
            ],
          };
        } else {
          result = {
            'content': [
              {'type': 'text', 'text': '服务暂不可用'},
            ],
            'isError': true,
          };
        }
      default:
        final payload = {
          'jsonrpc': '2.0',
          'id': body['id'],
          'error': {'code': -32601, 'message': 'Method not found'},
        };
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(payload));
        await response.close();
        return;
    }
    final payload = {'jsonrpc': '2.0', 'id': body['id'], 'result': result};
    if (sse) {
      response.headers.set('Content-Type', 'text/event-stream; charset=utf-8');
      // 先推一条无关通知，客户端应跳过。
      response.write(
        'event: message\ndata: ${jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/progress'})}\n\n',
      );
      response.write('event: message\ndata: ${jsonEncode(payload)}\n\n');
    } else {
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(payload));
    }
    await response.close();
  }
}

McpConnector _connector(String url, {Set<String> disabled = const {}}) =>
    McpConnector(
      id: 'abc123',
      url: url,
      bearerToken: 'secret',
      headers: const {'X-Extra': '1'},
      tools: const [
        McpToolInfo(
          name: 'get_weather',
          description: '查询天气',
          inputSchema: {
            'type': 'object',
            'properties': {
              'city': {'type': 'string'},
            },
            'additionalProperties': false,
          },
        ),
        McpToolInfo(name: 'get.news', description: '查新闻'),
      ],
      disabledTools: disabled,
    );

void main() {
  test('MCP outputSchema survives config serialization and tool assembly', () {
    final info=McpToolInfo.fromJson({'name':'structured','inputSchema':{'type':'object'},'outputSchema':{'type':'object','properties':{'ok':{'type':'boolean'}}}});
    expect(McpToolInfo.fromJson(info.toJson()).outputSchema,info.outputSchema);
    final connector=McpConnector(id:'structured',url:'https://invalid.test',tools:[info]);
    final plugin=McpConnectorPlugin(connector);
    expect(plugin.getTools().single.outputSchema,info.outputSchema);
  });
  group('McpHttpClient', () {
    for (final sse in [false, true]) {
      test('握手、翻页列举与调用工具（${sse ? 'SSE' : 'JSON'} 响应）', () async {
        final server = _FakeMcpServer(sse: sse);
        await server.start();
        addTearDown(server.close);
        final client = McpHttpClient(
          url: server.url,
          headers: const {'Authorization': 'Bearer secret', 'X-Extra': '1'},
        );
        addTearDown(client.close);

        final snapshot = await client.listTools();
        expect(snapshot.serverName, '天气服务');
        expect(snapshot.tools.map((t) => t.name), ['get_weather', 'get.news']);
        expect(server.requests.map((r) => r['method']), [
          'initialize',
          'notifications/initialized',
          'tools/list',
          'tools/list',
        ]);
        expect(server.headersSeen.last['session'], 'session-1');
        expect(server.headersSeen.last['version'], '2025-06-18');
        expect(server.headersSeen.last['x-extra'], '1');

        final result = await client.callTool('get_weather', {'city': '上海'});
        expect(result.isError, isFalse);
        expect(result.text, '上海：晴');
        expect(result.output?.images, hasLength(1));
      });
    }

    test('会话过期后重新握手一次并重发请求', () async {
      final server = _FakeMcpServer();
      await server.start();
      addTearDown(server.close);
      final client = McpHttpClient(
        url: server.url,
        headers: const {'Authorization': 'Bearer secret'},
      );
      addTearDown(client.close);

      await client.listTools();
      server.session = 'session-2';
      final result = await client.callTool('get_weather', {'city': '北京'});

      expect(result.text, startsWith('北京：晴'));
      expect(server.initializeCount, 2);
    });

    test('鉴权失败与 JSON-RPC 错误转成可读异常', () async {
      final server = _FakeMcpServer();
      await server.start();
      addTearDown(server.close);
      final unauthorized = McpHttpClient(url: server.url);
      addTearDown(unauthorized.close);
      await expectLater(
        unauthorized.listTools(),
        throwsA(
          isA<McpException>().having(
            (e) => e.message,
            'message',
            contains('鉴权失败'),
          ),
        ),
      );
    });

    test('完整结果交由运行器保全，不在 MCP 层截断', () {
      final text = McpHttpClient.flattenToolResult({
        'content': [
          {'type': 'text', 'text': 'x' * (McpHttpClient.maxResultChars + 10)},
        ],
      });
      expect(text.length, McpHttpClient.maxResultChars + 10);
      expect(text, isNot(contains('已截断')));
    });
  });

  group('McpToolNaming', () {
    test('工具名合法、可反查连接器且不超过 64 字符', () {
      final name = McpToolNaming.toolName('abc123', 'get.news');
      expect(name, 'mcp__abc123__get_news');
      expect(McpToolNaming.connectorIdOfTool(name), 'abc123');
      expect(McpToolNaming.connectorIdOfTool('web_search'), isNull);

      final long = McpToolNaming.toolName('abc123', 'a' * 100);
      expect(long.length, 64);
      expect(RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(long), isTrue);
      expect(long, isNot(McpToolNaming.toolName('abc123', '${'a' * 99}b')));
    });

    test('配置往返保留字段并丢弃非法 id', () {
      final config = McpConnectorsConfig(
        connectors: [
          _connector('https://x.example/mcp', disabled: {'get.news'}),
        ],
      );
      final decoded = McpConnectorsConfig.fromJson(
        jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>,
      );
      final c = decoded.connectors.single;
      expect(c.bearerToken, 'secret');
      expect(c.activeTools.map((t) => t.name), ['get_weather']);
      expect(
        McpConnectorsConfig.fromJson({
          'connectors': [
            {'id': 'bad__id', 'url': 'https://x'},
          ],
        }).connectors,
        isEmpty,
      );
    });
  });

  group('McpConnectorPlugin', () {
    test('按工具开关暴露工具，schema 规整，调用转发到服务', () async {
      final server = _FakeMcpServer();
      await server.start();
      addTearDown(server.close);
      final connector = _connector(server.url);
      final client = McpHttpClient(
        url: server.url,
        headers: connector.requestHeaders,
      );
      addTearDown(client.close);
      final plugin = McpConnectorPlugin(connector, clientFactory: () => client);

      expect(plugin.id, 'mcp:abc123');
      final tools = plugin.getTools();
      expect(tools.map((t) => t.name), [
        'mcp__abc123__get_weather',
        'mcp__abc123__get_news',
      ]);
      final schema = tools.first.toOpenAISchema()['function'] as Map;
      expect(schema['description'], '[${connector.displayName}] 查询天气');
      expect(
        (schema['parameters'] as Map).containsKey('additionalProperties'),
        isFalse,
      );
      expect((schema['parameters'] as Map)['type'], 'object');
      expect(tools.last.toAnthropicSchema()['input_schema'], {
        'type': 'object',
        'properties': <String, dynamic>{},
      });

      expect(await tools.first.handler({'city': '杭州'}), startsWith('杭州：晴'));
      expect(jsonDecode((await tools.last.handler({}))!), {'error': '服务暂不可用'});

      final partial = McpConnectorPlugin(
        _connector(server.url, disabled: {'get.news'}),
      );
      expect(partial.getTools().map((t) => t.name), [
        'mcp__abc123__get_weather',
      ]);
      expect(
        McpConnectorPlugin(
          _connector(server.url).copyWith(enabled: false),
        ).getTools(),
        isEmpty,
      );
    });
  });

  group('角色绑定', () {
    PluginManager manager() =>
        PluginManager()
          ..register(McpConnectorPlugin(_connector('https://x.example/mcp')));

    test('角色「全部插件」不包含连接器，显式开启才生效', () {
      const builder = ChatPluginContextBuilder();
      expect(
        builder.getEffectivePlugins(
          pluginManager: manager(),
          enabledPluginIds: null,
        ),
        isEmpty,
      );
      expect(
        builder
            .getEffectivePlugins(
              pluginManager: manager(),
              enabledPluginIds: {'mcp:abc123'},
            )
            .map((p) => p.id),
        ['mcp:abc123'],
      );
    });

    test('v2 原生安装：只声明请求能力、须显式开启、不处理回复', () {
      final plugin = McpConnectorPlugin(_connector('https://x.example/mcp'));
      final runtime = PluginRuntime.fromPlugins([plugin]);
      final installed = runtime.plugin('mcp:abc123')!;
      expect(installed.capabilities, {AppCapability.request});
      expect(installed.exposure, PluginExposure.roleExplicit);
      expect(runtime.selectForRole(null), isEmpty);
      expect(runtime.selectForRole({'mcp:abc123'}), ['mcp:abc123']);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ref = container.read(_refProvider);
      final scope = runtime
          .requestScopes(
            runtime.snapshot(),
            ['mcp:abc123'],
            PluginRequestInputs(
              ref: ref,
              settings: mapUiModelsToAppSettings(const {}),
              imageConfig: const ImageConfig(),
              voiceRequest: VoiceRequest(ownerId: 'role'),
              pluginPrompts: const PluginPrompts(),
              history: const [],
              previousUserMessageTime: null,
              useFastImageRoute: false,
              useStableImageRoute: true,
              supportsToolCalling: true,
              reminders: const SystemReminderService(),
            ),
          )
          .single;
      expect(scope.active, isTrue);
      expect(scope.tools().map((t) => t.name),
          plugin.getTools().map((t) => t.name));
      expect(scope.reminders(DateTime(2026)), isEmpty);
      expect(
        runtime.responseProcessors(
          runtime.snapshot(),
          ['mcp:abc123'],
          PluginResponseInputs(ref: ref, voiceRequest: null),
        ),
        isEmpty,
      );
    });

    test('连接器未开启时历史里的工具调用与结果成对移出请求副本', () {
      final messages = [
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call_1',
              'type': 'function',
              'function': {
                'name': 'mcp__abc123__get_weather',
                'arguments': '{}',
              },
            },
          ],
        },
        {
          'role': 'tool',
          'tool_call_id': 'call_1',
          'name': 'mcp__abc123__get_weather',
          'content': '晴',
        },
        {'role': 'user', 'content': '谢谢'},
      ];
      final off = ChatPluginContextPolicy.firstParty(activeProviderIds: {});
      expect(off.filterMessages(messages), [
        {'role': 'user', 'content': '谢谢'},
      ]);
      final on = ChatPluginContextPolicy.firstParty(
        activeProviderIds: {'mcp:abc123'},
      );
      expect(on.filterMessages(messages), hasLength(3));
    });
  });

  test('请求头逐行解析，格式不对报错', () {
    expect(parseHeaderLines('X-Api-Key: abc\n\nX-Other:1'), {
      'X-Api-Key': 'abc',
      'X-Other': '1',
    });
    expect(() => parseHeaderLines('no colon'), throwsFormatException);
  });
}

import 'dart:convert';
import 'package:aicove_flutter/src/features/plugins/mcp/mcp_connector.dart';
import 'package:aicove_flutter/src/features/plugins/mcp/mcp_connector_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/mcp/mcp_http_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

void main() {
  test(
    'MCP forwards mixed images, errors, structure and audio explanation',
    () async {
      final image = base64Encode(img.encodePng(img.Image(width: 2, height: 3)));
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        if (body['method'] == 'notifications/initialized') {
          return http.Response('', 202);
        }
        final result = body['method'] == 'initialize'
            ? {
                'protocolVersion': McpHttpClient.protocolVersion,
                'serverInfo': {'name': 'rich'},
              }
            : {
                'content': [
                  {'type': 'text', 'text': 'mixed'},
                  {'type': 'image', 'mimeType': 'image/png', 'data': image},
                  {'type': 'audio', 'mimeType': 'audio/wav', 'data': 'ignored'},
                ],
                'isError': true,
                'structuredContent': {'value': 42},
              };
        return http.Response(
          jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      addTearDown(client.close);
      final mcp = McpHttpClient(url: 'https://invalid.test', client: client);
      final connector = McpConnectorPlugin(
        const McpConnector(
          id: 'rich',
          url: 'https://invalid.test',
          tools: [McpToolInfo(name: 'read')],
        ),
        clientFactory: () => mcp,
      );
      final tool = connector.getTools().single;
      final output = await tool.invoke({});
      expect(output.text, allOf(contains('mixed'), contains('音频')));
      expect(output.isError, true);
      expect(output.structured, {'value': 42});
      expect(output.images, hasLength(1));
      expect(output.images.single.width, 2);
      expect(output.images.single.height, 3);
      expect(output.persistentText, isNot(contains(image)));
      expect(await tool.handler({}), contains('［图片已省略：MCP read］'));
    },
  );
  test('MCP image-only results do not invent text', () async {
    expect(
      McpHttpClient.flattenToolResult({
        'content': [
          {'type': 'image', 'mimeType': 'image/png', 'data': 'AAAA'},
        ],
      }, includeImagePlaceholder: false),
      '',
    );
  });
  for (final n in [
    McpHttpClient.maxResultChars - 1,
    McpHttpClient.maxResultChars,
    McpHttpClient.maxResultChars + 1,
  ]) {
    test('MCP preserves all $n characters for the shared result store', () {
      final text = McpHttpClient.flattenToolResult({
        'content': [
          {'type': 'text', 'text': 'x' * n},
        ],
      });
      expect(text, 'x' * n);
    });
  }
}

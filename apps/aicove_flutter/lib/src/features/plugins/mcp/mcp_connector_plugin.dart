import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/app_logger.dart';
import '../../agent_plugins/aicove_plugin.dart';
import '../domain/index.dart';
import 'mcp_connector.dart';
import 'mcp_connector_agent_plugin.dart';
import 'mcp_http_client.dart';

/// 一个 MCP 连接器对应的插件，id 为 `mcp:<连接器id>`。
///
/// 只走 Function Calling：工具来自连接器保存的工具清单，调用时经
/// [McpClientPool] 复用会话转发到远程服务。角色未显式开启时不生效
/// （见 `ChatPluginContextBuilder.getEffectivePlugins`）。
class McpConnectorPlugin extends BasePlugin {
  McpConnectorPlugin(this.connector, {McpHttpClient Function()? clientFactory})
    : _clientFactory = clientFactory,
      super(
        metadata: PluginMetadata(
          id: McpToolNaming.pluginIdOf(connector.id),
          name: connector.displayName,
          description: 'MCP 连接器',
          version: '1.0.0',
          author: 'User',
          icon: Icons.hub_outlined,
        ),
      );

  final McpConnector connector;
  final McpHttpClient Function()? _clientFactory;

  static const _logTag = 'McpConnectorPlugin';

  @override
  bool get enabled => connector.isUsable;

  @override
  AicovePlugin get agentPlugin => mcpConnectorAgentPlugin(this);

  List<AITool> getTools() {
    if (!enabled) return const [];
    return [
      for (final tool in connector.activeTools)
        AITool(
          name: McpToolNaming.toolName(connector.id, tool.name),
          description: _describe(tool),
          parameters: const {},
          inputSchema: normalizeInputSchema(tool.inputSchema),
          handler: (args) => _call(tool.name, args),
        ),
    ];
  }

  String _describe(McpToolInfo tool) {
    final text = tool.description.trim().isEmpty
        ? tool.displayName
        : tool.description.trim();
    return '[${connector.displayName}] $text';
  }

  Future<String?> _call(String toolName, Map<String, dynamic> args) async {
    final client =
        _clientFactory?.call() ?? McpClientPool.instance.clientFor(connector);
    try {
      final result = await client.callTool(toolName, args);
      if (!result.isError) return result.text;
      return jsonEncode({
        'error': result.text.isEmpty ? '工具执行失败' : result.text,
      });
    } on McpException catch (e) {
      AppLogger.warning(
        _logTag,
        'MCP 工具调用失败',
        metadata: {
          'connector': connector.id,
          'tool': toolName,
          'error': e.message,
        },
      );
      return jsonEncode({'error': e.message});
    }
  }

  /// 把服务端 inputSchema 收成各家都接受的顶层 object，并去掉部分供应商
  /// 不认识的元信息字段。
  static Map<String, dynamic> normalizeInputSchema(
    Map<String, dynamic> schema,
  ) {
    final cleaned = _strip(schema) as Map<String, dynamic>;
    return {
      ...cleaned,
      'type': 'object',
      'properties': cleaned['properties'] is Map
          ? cleaned['properties']
          : <String, dynamic>{},
    };
  }

  static const _droppedKeys = {
    r'$schema',
    r'$id',
    r'$comment',
    'additionalProperties',
  };

  static Object? _strip(Object? value) {
    if (value is Map) {
      return <String, dynamic>{
        for (final entry in value.entries)
          if (!_droppedKeys.contains(entry.key))
            entry.key.toString(): _strip(entry.value),
      };
    }
    if (value is List) return value.map(_strip).toList();
    return value;
  }
}

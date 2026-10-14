import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/app_logger.dart';
import '../../../core/sync/cloud_setting_policy.dart';
import 'mcp_connector.dart';
import 'mcp_http_client.dart';

/// MCP 连接器配置 Provider。
final mcpConnectorsConfigProvider =
    StateNotifierProvider<McpConnectorsConfigNotifier, McpConnectorsConfig>(
      (ref) => McpConnectorsConfigNotifier(),
    );

/// MCP 连接器配置：与其它插件配置一样存于 `aicove.plugins.*`，随用户自己的
/// 云同步／局域网同步走，角色在别的设备上也能找到绑定的连接器。
class McpConnectorsConfigNotifier extends StateNotifier<McpConnectorsConfig> {
  McpConnectorsConfigNotifier({McpHttpClient Function(McpConnector)? connect})
    : _connect = connect,
      super(const McpConnectorsConfig()) {
    ready = _load();
  }

  static const storageKey = 'aicove.plugins.mcp.connectors.v1';
  static const _logTag = 'McpConnectorsConfigNotifier';

  final McpHttpClient Function(McpConnector)? _connect;
  late final Future<void> ready;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(storageKey);
      if (json != null && json.isNotEmpty) {
        state = McpConnectorsConfig.fromJson(
          jsonDecode(json) as Map<String, dynamic>,
        );
      }
    } catch (e) {
      AppLogger.warning(_logTag, '读取配置失败', metadata: {'error': '$e'});
    }
  }

  Future<void> _write(McpConnectorsConfig config) async {
    await ready;
    final prefs = await SharedPreferences.getInstance();
    if (!await saveCloudPreference(
      prefs,
      storageKey,
      jsonEncode(config.toJson()),
    )) {
      throw StateError('MCP 连接器配置写入失败');
    }
    if (mounted) state = config;
  }

  Future<void> saveConnector(McpConnector connector) async {
    await ready;
    final exists = state.connectors.any((c) => c.id == connector.id);
    await _write(
      McpConnectorsConfig(
        connectors: [
          for (final c in state.connectors)
            c.id == connector.id ? connector : c,
          if (!exists) connector,
        ],
      ),
    );
  }

  Future<void> removeConnector(String id) async {
    await ready;
    await _write(
      McpConnectorsConfig(
        connectors: [
          for (final c in state.connectors)
            if (c.id != id) c,
        ],
      ),
    );
    McpClientPool.instance.remove(id);
  }

  /// 连接服务并重新拉取工具清单；失败抛出 [McpException]，原有清单保留。
  Future<McpConnector> refreshTools(String id) async {
    await ready;
    final connector = state.byId(id);
    if (connector == null) throw const McpException('连接器不存在');
    if (!connector.hasValidUrl) throw const McpException('请先填写 http(s) 地址');
    final client =
        _connect?.call(connector) ??
        McpClientPool.instance.clientFor(connector);
    final snapshot = await client.listTools();
    final latest = state.byId(id) ?? connector;
    final names = {for (final tool in snapshot.tools) tool.name};
    final updated = latest.copyWith(
      tools: snapshot.tools,
      serverName: snapshot.serverName,
      toolsFetchedAt: DateTime.now(),
      // 服务端已移除的工具不再保留关闭记录。
      disabledTools: latest.disabledTools.where(names.contains).toSet(),
    );
    await saveConnector(updated);
    return updated;
  }
}

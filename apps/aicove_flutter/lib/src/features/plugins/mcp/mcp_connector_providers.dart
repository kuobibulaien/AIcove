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
  McpConnectorsConfigNotifier({this._connect})
    : super(const McpConnectorsConfig()) {
    ready = _load();
  }

  static const storageKey = 'aicove.plugins.mcp.connectors.v1';
  static const localStorageKey = 'aicove.local.mcp.stdio.v1';
  final _revisions = <String, int>{};
  Future<void> _writes = Future<void>.value();

  static const _logTag = 'McpConnectorsConfigNotifier';

  final McpClientPort Function(McpConnector)? _connect;
  late final Future<void> ready;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(storageKey);
      if (json != null && json.isNotEmpty) {
        final shared = McpConnectorsConfig.fromJson(
          jsonDecode(json) as Map<String, dynamic>,
        );
        final localRaw = prefs.getString(localStorageKey);
        var local = <String, dynamic>{};
        if (localRaw != null) {
          try {
            local = jsonDecode(localRaw) as Map<String, dynamic>;
          } catch (_) {
            AppLogger.warning(_logTag, '本机启动配置无法读取，请在本机重新配置');
          }
        }
        state = McpConnectorsConfig(
          connectors: [
            for (final c in shared.connectors)
              c.isStdio && local[c.id] is Map
                  ? c.withLocalJson(
                      Map<String, dynamic>.from(local[c.id] as Map),
                    )
                  : c,
          ],
        );
      }
    } catch (e) {
      AppLogger.warning(
        _logTag,
        '读取配置失败',
        metadata: {'error': e.runtimeType.toString()},
      );
    }
  }

  Future<void> _write(McpConnectorsConfig config) async {
    await ready;
    final prefs = await SharedPreferences.getInstance();
    if ((config.connectors.any((c) => c.isStdio) ||
            prefs.containsKey(localStorageKey)) &&
        !await prefs.setString(
          localStorageKey,
          jsonEncode({
            for (final c in config.connectors)
              if (c.isStdio) c.id: c.localToJson(),
          }),
        )) {
      throw StateError('MCP 本机配置写入失败');
    }
    if (!await saveCloudPreference(
      prefs,
      storageKey,
      jsonEncode(config.toJson()),
    )) {
      throw StateError('MCP 连接器配置写入失败');
    }
    if (mounted) state = config;
  }

  Future<void> _mutate(Future<void> Function() action) {
    final result = _writes.then((_) => action());
    _writes = result.catchError((Object _) {});
    return result;
  }

  Future<void> saveConnector(McpConnector connector) async {
    await ready;
    await _mutate(() => _saveConnector(connector));
  }

  Future<void> _saveConnector(McpConnector connector) async {
    final previous = state.byId(connector.id);
    final changed =
        previous != null &&
        previous.connectionFingerprint != connector.connectionFingerprint;
    if (changed || !connector.enabled) {
      _revisions[connector.id] = (_revisions[connector.id] ?? 0) + 1;
      McpClientPool.instance.remove(connector.id);
    }
    if (changed) connector = connector.copyWith(clearSnapshot: true);
    final exists = previous != null;
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
    await _mutate(() async {
      _revisions[id] = (_revisions[id] ?? 0) + 1;
      McpClientPool.instance.remove(id);
      await _write(
        McpConnectorsConfig(
          connectors: [
            for (final c in state.connectors)
              if (c.id != id) c,
          ],
        ),
      );
    });
  }

  /// 连接服务并重新拉取工具清单；失败抛出 [McpException]，原有清单保留。
  Future<McpConnector> refreshTools(String id) async {
    await ready;
    final connector = state.byId(id);
    if (connector == null) throw const McpException('连接器不存在');
    if (!connector.hasValidConfiguration) {
      throw McpException(
        connector.isStdio ? '请在桌面端填写本机启动命令' : '请先填写 http(s) 地址',
      );
    }
    final revision = _revisions[id] ?? 0;
    final client =
        _connect?.call(connector) ??
        McpClientPool.instance.clientFor(connector);
    final snapshot = await client.listTools();
    late McpConnector updatedResult;
    await _mutate(() async {
      final latest = state.byId(id);
      if (latest == null ||
          (_revisions[id] ?? 0) != revision ||
          latest.connectionFingerprint != connector.connectionFingerprint) {
        throw const McpException('连接配置已变更，请重新测试连接');
      }
      final names = {for (final tool in snapshot.tools) tool.name};
      final updated = latest.copyWith(
        tools: snapshot.tools,
        serverName: snapshot.serverName,
        toolsFetchedAt: DateTime.now(),
        // 服务端已移除的工具不再保留关闭记录。
        disabledTools: latest.disabledTools.where(names.contains).toSet(),
      );
      await _saveConnector(updated);
      updatedResult = updated;
    });
    return updatedResult;
  }
}

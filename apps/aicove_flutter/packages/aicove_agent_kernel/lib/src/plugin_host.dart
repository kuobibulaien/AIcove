import 'dart:async';

import 'scope.dart';
import 'stages.dart';
import 'types.dart';

enum KernelCapability {
  /// May register tools.
  tools,

  /// May register content contributors (contribute-only hooks, ADR0063).
  contribute,
}

/// How a failing hook affects the run.
enum ErrorPolicy {
  /// Failure fails the run.
  required,

  /// Failure is reported and skipped; the run continues.
  optional,
}

class KernelTool {
  const KernelTool({
    required this.name,
    required this.schema,
    required this.handler,
  });

  final String name;

  /// Provider-facing schema, passed through untouched.
  final Map<String, dynamic> schema;
  final Future<String> Function(Map<String, dynamic> args) handler;
}

/// Read-only input for content contributors.
class ContributionInput {
  const ContributionInput(this.data);
  final Map<String, Object?> data;
}

typedef ContentContributor = Future<List<String>> Function(
  ContributionInput input,
);

class KernelPlugin {
  const KernelPlugin({
    required this.id,
    required this.capabilities,
    required this.setup,
  });

  final String id;
  final Set<KernelCapability> capabilities;

  /// Called on every enable; registrations are revoked on disable.
  final void Function(PluginRegistrar registrar) setup;
}

class PluginRegistrar {
  PluginRegistrar._(this._host, this._plugin);

  final PluginHost _host;
  final KernelPlugin _plugin;

  void tool(KernelTool tool) {
    _require(KernelCapability.tools);
    _host._addTool(_plugin.id, tool);
  }

  void contributor(
    ContentContributor contributor, {
    ErrorPolicy policy = ErrorPolicy.optional,
  }) {
    _require(KernelCapability.contribute);
    _host._addContributor(_plugin.id, contributor, policy);
  }

  void _require(KernelCapability capability) {
    if (!_plugin.capabilities.contains(capability)) {
      throw StateError('插件 ${_plugin.id} 未声明能力：${capability.name}');
    }
  }
}

class _OwnedTool {
  const _OwnedTool(this.owner, this.tool);
  final String owner;
  final KernelTool tool;
}

class _OwnedContributor {
  const _OwnedContributor(this.owner, this.contributor, this.policy);
  final String owner;
  final ContentContributor contributor;
  final ErrorPolicy policy;
}

/// Plugin registry with owner-tracked contributions in an app scope.
/// Runs take a snapshot, so disabling a plugin affects the next run only.
class PluginHost {
  PluginHost(this.scope);

  final KernelScope scope;
  final Map<String, KernelPlugin> _plugins = {};
  final Set<String> _enabled = {};
  final Map<String, _OwnedTool> _tools = {};
  final List<_OwnedContributor> _contributors = [];

  bool isEnabled(String pluginId) => _enabled.contains(pluginId);

  void install(KernelPlugin plugin, {bool enabled = true}) {
    if (_plugins.containsKey(plugin.id)) {
      throw StateError('插件已安装：${plugin.id}');
    }
    _plugins[plugin.id] = plugin;
    if (enabled) enable(plugin.id);
  }

  void enable(String pluginId) {
    final plugin = _plugins[pluginId];
    if (plugin == null) throw StateError('插件未安装：$pluginId');
    if (!_enabled.add(pluginId)) return;
    try {
      plugin.setup(PluginRegistrar._(this, plugin));
    } catch (_) {
      scope.revokeOwner(pluginId);
      _enabled.remove(pluginId);
      rethrow;
    }
  }

  void disable(String pluginId) {
    if (!_enabled.remove(pluginId)) return;
    scope.revokeOwner(pluginId);
  }

  /// Fixes the tool set and contributors for one run.
  ///
  /// When [requestTools] is non-null it is authoritative, even if empty;
  /// otherwise the enabled plugins' tools are used.
  RunSnapshot snapshot({List<KernelTool>? requestTools}) {
    final Map<String, KernelTool> tools;
    if (requestTools != null) {
      tools = {};
      for (final tool in requestTools) {
        if (tools.containsKey(tool.name)) {
          throw StateError('重复工具名称：${tool.name}');
        }
        tools[tool.name] = tool;
      }
    } else {
      tools = {for (final e in _tools.entries) e.key: e.value.tool};
    }
    return RunSnapshot._(
      Map.unmodifiable(tools),
      List.unmodifiable(_contributors),
    );
  }

  void _addTool(String owner, KernelTool tool) {
    if (_tools.containsKey(tool.name)) {
      throw StateError('重复工具名称：${tool.name}');
    }
    final entry = _OwnedTool(owner, tool);
    _tools[tool.name] = entry;
    scope.track(owner, () {
      if (identical(_tools[tool.name], entry)) _tools.remove(tool.name);
    });
  }

  void _addContributor(
    String owner,
    ContentContributor contributor,
    ErrorPolicy policy,
  ) {
    final entry = _OwnedContributor(owner, contributor, policy);
    _contributors.add(entry);
    scope.track(owner, () => _contributors.remove(entry));
  }
}

class ContributionFailure {
  const ContributionFailure(this.owner, this.error);
  final String owner;
  final Object error;
}

class RunSnapshot {
  RunSnapshot._(this.tools, this._contributors);

  final Map<String, KernelTool> tools;
  final List<_OwnedContributor> _contributors;

  /// Collects contributions in registration order. Optional contributors that
  /// throw are reported via [onFailure] and skipped; required ones rethrow.
  Future<List<String>> collectContributions(
    ContributionInput input, {
    void Function(ContributionFailure failure)? onFailure,
  }) async {
    final out = <String>[];
    for (final entry in _contributors) {
      try {
        out.addAll(await entry.contributor(input));
      } catch (error) {
        if (entry.policy == ErrorPolicy.required) rethrow;
        onFailure?.call(ContributionFailure(entry.owner, error));
      }
    }
    return out;
  }
}

/// Default ⑦ executor backed by a [RunSnapshot]. Unknown tools, handler
/// errors and timeouts become structured error results; the loop continues.
class RegistryToolExecutor implements ToolBatchExecutor {
  RegistryToolExecutor(
    this.snapshot, {
    required this.timeout,
    BatchMode Function(List<KernelToolCall> calls)? modeFor,
  }) : _modeFor = modeFor;

  final RunSnapshot snapshot;
  final Duration timeout;
  final BatchMode Function(List<KernelToolCall> calls)? _modeFor;

  @override
  BatchMode modeFor(List<KernelToolCall> calls, TurnContext ctx) =>
      _modeFor?.call(calls) ?? BatchMode.serial;

  @override
  Future<KernelToolResult> executeOne(
    KernelToolCall call,
    TurnContext ctx,
  ) async {
    final tool = snapshot.tools[call.name];
    if (tool == null) {
      return KernelToolResult(
        callId: call.id,
        name: call.name,
        content: '未找到工具：${call.name}',
        isError: true,
      );
    }
    try {
      final content = await tool.handler(call.arguments).timeout(timeout);
      return KernelToolResult(callId: call.id, name: call.name, content: content);
    } on TimeoutException {
      return KernelToolResult(
        callId: call.id,
        name: call.name,
        content: '工具执行超时：${call.name}',
        isError: true,
      );
    } catch (error) {
      return KernelToolResult(
        callId: call.id,
        name: call.name,
        content: '工具执行失败：$error',
        isError: true,
      );
    }
  }
}

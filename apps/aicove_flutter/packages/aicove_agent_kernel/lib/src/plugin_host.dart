import 'dart:async';

import 'scope.dart';
import 'stages.dart';
import 'types.dart';

/// A permission a plugin declares before it may register a kind of
/// contribution. The kernel defines its own; hosts add more (e.g. prompts).
/// Compared by identity: always use the shared `const` instance.
final class KernelCapability {
  const KernelCapability(this.name);

  final String name;

  /// May register tools.
  static const tools = KernelCapability('tools');

  /// May register content contributors (contribute-only hooks, ADR0063).
  static const contribute = KernelCapability('contribute');

  /// May provide services in the host scope.
  static const services = KernelCapability('services');

  @override
  String toString() => 'KernelCapability($name)';
}

/// What running a tool does, so a [ToolGate] can decide per agent policy.
enum ToolEffect {
  /// Reads whitelisted diagnostics only (ids, counts, timings, states).
  readDiagnostic,

  /// Reads private content such as chat text, memories or role settings.
  readPrivate,

  /// Reversible change to settings or configuration.
  write,

  /// Deletes data; must back up before running.
  destructive,

  /// Side effects on an external service (image generation, search, MCP).
  external,
}

/// Typed key for host-defined contributions such as prompt fragments.
class ContributionKey<T> {
  const ContributionKey(this.name, this.capability);

  final String name;

  /// Capability a plugin must declare to add to this key.
  final KernelCapability capability;

  @override
  String toString() => 'ContributionKey<$T>($name)';
}

/// A contribution together with the plugin that registered it.
class Owned<T> {
  const Owned(this.owner, this.value);
  final String owner;
  final T value;
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
    this.effect = ToolEffect.external,
    this.agentIds,
  });

  final String name;
  final ToolEffect effect;

  /// Agents that may see this tool; null means every agent.
  final Set<String>? agentIds;

  bool visibleTo(String? agentId) =>
      agentIds == null || (agentId != null && agentIds!.contains(agentId));

  /// Provider-facing schema, passed through untouched.
  final Map<String, dynamic> schema;
  final Future<String> Function(Map<String, dynamic> args) handler;
}

/// Read-only input for content contributors.
///
/// [data] is a deep unmodifiable copy (maps, lists and sets at any depth), so
/// a contributor cannot change what later contributors see; an attempt throws
/// and is handled like any other contributor error.
class ContributionInput {
  ContributionInput(Map<String, Object?> data)
      : data = _freeze(data) as Map<String, Object?>;
  final Map<String, Object?> data;

  static Object? _freeze(Object? value) => switch (value) {
        Map<String, Object?>() => Map<String, Object?>.unmodifiable(
            {for (final e in value.entries) e.key: _freeze(e.value)}),
        Map() => Map.unmodifiable(
            {for (final e in value.entries) e.key: _freeze(e.value)}),
        List() => List.unmodifiable(value.map(_freeze)),
        Set() => Set.unmodifiable(value.map(_freeze)),
        _ => value,
      };
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

  /// Called on every enable; registrations are revoked on disable. The
  /// registrar is valid only during this synchronous call.
  final void Function(PluginRegistrar registrar) setup;
}

class PluginRegistrar {
  PluginRegistrar._(this._host, this._plugin);

  final PluginHost _host;
  final KernelPlugin _plugin;
  bool _open = true;

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

  /// Provides a service in the host scope until the plugin is disabled.
  void service<T>(ServiceKey<T> key, T service) {
    _require(KernelCapability.services);
    _host.scope.provide(key, service, owner: _plugin.id);
  }

  /// Adds a host-defined contribution; requires [ContributionKey.capability].
  void add<T>(ContributionKey<T> key, T value) {
    _require(key.capability);
    _host._addContribution(_plugin.id, key, value);
  }

  void _require(KernelCapability capability) {
    if (!_open) {
      throw StateError('插件 ${_plugin.id} 的注册器只能在 setup 期间使用');
    }
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
  final Map<ContributionKey<Object?>, List<Owned<Object?>>> _contributions =
      {};

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
    final registrar = PluginRegistrar._(this, plugin);
    try {
      plugin.setup(registrar);
    } catch (_) {
      scope.revokeOwner(pluginId);
      _enabled.remove(pluginId);
      rethrow;
    } finally {
      registrar._open = false;
    }
  }

  void disable(String pluginId) {
    if (!_enabled.remove(pluginId)) return;
    scope.revokeOwner(pluginId);
  }

  /// Fixes the tool set and contributions for one run.
  ///
  /// When [requestTools] is non-null it is authoritative, even if empty;
  /// otherwise the enabled plugins' tools are used. Either way, tools limited
  /// to other agents are dropped for [agentId].
  RunSnapshot snapshot({List<KernelTool>? requestTools, String? agentId}) {
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
    tools.removeWhere((_, tool) => !tool.visibleTo(agentId));
    return RunSnapshot._(
      Map.unmodifiable(tools),
      List.unmodifiable(_contributors),
      {
        for (final e in _contributions.entries)
          e.key: List<Owned<Object?>>.unmodifiable(e.value),
      },
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

  void _addContribution<T>(String owner, ContributionKey<T> key, T value) {
    final entry = Owned<Object?>(owner, value);
    final list = _contributions.putIfAbsent(key, () => []);
    list.add(entry);
    scope.track(owner, () => list.remove(entry));
  }
}

class ContributionFailure {
  const ContributionFailure(this.owner, this.error);
  final String owner;
  final Object error;
}

class RunSnapshot {
  RunSnapshot._(this.tools, this._contributors, this._contributions);

  final Map<String, KernelTool> tools;
  final List<_OwnedContributor> _contributors;
  final Map<ContributionKey<Object?>, List<Owned<Object?>>> _contributions;

  /// Contributions for [key] in registration order, fixed at snapshot time.
  List<Owned<T>> contributionsOf<T>(ContributionKey<T> key) => [
        for (final entry in _contributions[key] ?? const <Owned<Object?>>[])
          Owned<T>(entry.owner, entry.value as T),
      ];

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

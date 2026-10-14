import 'package:aicove_flutter/src/features/agent_plugins/aicove_plugin.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_request_context.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_request_scope.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_response.dart';
import 'package:aicove_flutter/src/features/plugins/domain/base_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';

/// Test plugin with the pre-batch-2c method shape: subclasses override the
/// methods they need, and [agentPlugin] contributes them through the v2
/// registrar.
abstract class TestPlugin extends BasePlugin {
  TestPlugin({required super.metadata});

  Future<String?> getSystemPrompt({
    String? userMessage,
    bool supportsToolCalling = false,
  }) async =>
      null;

  List<AITool> getTools() => const [];

  Future<PluginProcessResult> processResponse(String text) async =>
      PluginProcessResult(processedText: text, events: const []);

  @override
  AicovePlugin get agentPlugin => AicovePlugin(
        id: id,
        name: name,
        capabilities: const {AppCapability.request, AppCapability.responses},
        setup: (registrar) {
          registrar.add(
            AppContributions.requestScope,
            (_) => _TestScope(this),
          );
          registrar.add(
            AppContributions.responseProcessor,
            (_) => ResponseFunction(id, processResponse),
          );
        },
      );
}

class _TestScope extends PluginRequestScope {
  _TestScope(this.plugin);

  final TestPlugin plugin;

  @override
  String get pluginId => plugin.id;

  @override
  String get pluginName => plugin.name;

  @override
  bool get active => plugin.enabled;

  @override
  Future<String?> prompt(PluginRequestContext ctx) => plugin.getSystemPrompt(
        userMessage: ctx.userMessage,
        supportsToolCalling: ctx.supportsToolCalling,
      );

  @override
  List<AITool> tools() => plugin.getTools();
}

/// Reply processors of test plugins, in the given order.
List<PluginResponseProcessor> testProcessors(List<TestPlugin> plugins) => [
      for (final plugin in plugins) ResponseFunction(plugin.id, plugin.processResponse),
    ];

/// Tools of test plugins; runners only look tools up in what they are given.
List<AITool> testTools(List<TestPlugin> plugins) => [
      for (final plugin in plugins) ...plugin.getTools(),
    ];

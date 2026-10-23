import 'package:flutter/material.dart';

import '../../agent_plugins/aicove_plugin.dart';
import '../../agent_plugins/plugin_request_context.dart';
import '../../agent_plugins/plugin_request_scope.dart';
import '../domain/index.dart';
import 'aicove_package.dart';
import 'package_skill_tools.dart';
import 'package_script.dart';

/// An installed declarative package, registered as plugin `pkg:<id>`. Roles
/// must turn it on explicitly; "all plugins" does not include it.
class PackagePlugin extends BasePlugin {
  PackagePlugin(this.package)
    : super(
        metadata: PluginMetadata(
          id: package.pluginId,
          name: package.name,
          description: package.description.isEmpty
              ? '声明式包'
              : package.description,
          version: package.version,
          author: 'User',
          icon: Icons.inventory_2_outlined,
        ),
      );

  final AicovePackage package;
  late final script = PackageScript(package);

  Future<void> prepare() => script.load();

  Future<String?> prompt() async {
    await prepare();
    final fragments = [...package.prompts, ...script.prompts];
    return fragments.isEmpty ? null : fragments.join('\n\n');
  }

  static bool isExecutionTool(String name) =>
      name.startsWith('pkg_') || name.startsWith('run_skill_js_');

  @override
  bool get enabled => true;

  /// Tool the model calls to read one of the package's skills by name.
  String get readSkillTool => 'read_skill_${package.id}';

  @override
  AicovePlugin get agentPlugin => AicovePlugin(
    id: id,
    name: name,
    exposure: PluginExposure.roleExplicit,
    capabilities: const {AppCapability.request},
    contentTags: package.contentTagProvider(readSkillTool: readSkillTool),
    setup: (registrar) => registrar.add(
      AppContributions.requestScope,
      (_) => PackageRequestScope(this),
    ),
  );

  List<AITool> getTools({bool executable = true}) => [
    ...PackageSkillTools(package).tools(executable: executable),
    if (executable) ...script.tools(),
  ];
}

/// Prompts go to the end of the system prompt; skills through the
/// package's read tool.
class PackageRequestScope extends PluginRequestScope {
  PackageRequestScope(this.plugin);

  final PackagePlugin plugin;

  @override
  String get pluginId => plugin.id;

  @override
  String get pluginName => plugin.name;

  @override
  bool get active => plugin.enabled;

  @override
  Future<String?> prompt(PluginRequestContext ctx) async {
    return plugin.prompt();
  }

  @override
  List<AITool> tools() => plugin.getTools();
}

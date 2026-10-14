import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show ToolEffect;
import 'package:flutter/material.dart';

import '../../agent_plugins/aicove_plugin.dart';
import '../../agent_plugins/plugin_request_context.dart';
import '../../agent_plugins/plugin_request_scope.dart';
import '../domain/index.dart';
import 'aicove_package.dart';

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

  List<AITool> getTools() {
    final skills = package.skills;
    if (skills.isEmpty) return const [];
    return [
      AITool(
        name: readSkillTool,
        description:
            '读取「${package.name}」里的说明文档。可读的文档：'
            '${skills.map((s) => s.title.isEmpty ? s.name : '${s.name}（${s.title}）').join('、')}',
        parameters: const {},
        inputSchema: {
          'type': 'object',
          'properties': {
            'name': {
              'type': 'string',
              'enum': [for (final skill in skills) skill.name],
              'description': '文档名',
            },
          },
          'required': ['name'],
        },
        effect: ToolEffect.readDiagnostic,
        handler: (args) async {
          final name = args['name'];
          for (final skill in skills) {
            if (skill.name == name) return skill.content;
          }
          return '没有名为「$name」的文档';
        },
      ),
    ];
  }
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
    final prompts = plugin.package.prompts;
    return prompts.isEmpty ? null : prompts.join('\n\n');
  }

  @override
  List<AITool> tools() => plugin.getTools();
}

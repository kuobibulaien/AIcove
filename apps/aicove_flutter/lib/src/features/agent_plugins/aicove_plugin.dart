/// App-side plugin API v2 on top of the kernel plugin host (ADR0064 batch 2,
/// see docs/02_前后端分离与架构规范/Agent运行时第二批实施方案.md §3.2).
///
/// Plugins only contribute through the registrar; the assembly core collects
/// contributions in registration order and never checks plugin types.
library;

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';

import '../content_tags/domain/content_tag_spec.dart';
import 'plugin_request_scope.dart';
import 'plugin_response.dart';

/// Which runs include a plugin.
sealed class PluginExposure {
  const PluginExposure();

  /// Included when a role enables "all plugins".
  static const roleDefault = RoleDefaultExposure._();

  /// Only when a role enables it explicitly (MCP connectors, packages).
  static const roleExplicit = RoleExplicitExposure._();

  /// Always included and never listed in role settings; the plugin decides
  /// from the request inputs whether it applies (tavern compatibility).
  static const builtin = BuiltinExposure._();
}

final class RoleDefaultExposure extends PluginExposure {
  const RoleDefaultExposure._();
}

final class RoleExplicitExposure extends PluginExposure {
  const RoleExplicitExposure._();
}

final class BuiltinExposure extends PluginExposure {
  const BuiltinExposure._();
}

/// Only for the listed agent definitions; never shown in role settings.
final class AgentOnlyExposure extends PluginExposure {
  const AgentOnlyExposure(this.agentIds);
  final Set<String> agentIds;
}

/// Capabilities for app-level contributions. Kernel ones (`tools`,
/// `contribute`, `services`) live in [KernelCapability].
abstract final class AppCapability {
  /// May contribute a per-request scope (prompts, reminders, tools).
  static const request = KernelCapability('request');

  /// May post-process assistant replies.
  static const responses = KernelCapability('responses');
}

abstract final class AppContributions {
  static const requestScope = ContributionKey<PluginRequestScopeFactory>(
    'requestScope',
    AppCapability.request,
  );
  static const responseProcessor =
      ContributionKey<PluginResponseProcessorFactory>(
    'responseProcessor',
    AppCapability.responses,
  );
}

class AicovePlugin {
  const AicovePlugin({
    required this.id,
    required this.name,
    required this.capabilities,
    required this.setup,
    this.exposure = PluginExposure.roleDefault,
    this.contentTags,
  });

  final String id;
  final String name;
  final PluginExposure exposure;
  final Set<KernelCapability> capabilities;

  /// Content tags and tools the plugin owns beyond the first-party ones
  /// (ADR0044); the request copy strips them while the plugin is off.
  final ContentTagProvider? contentTags;

  /// Called on every enable; all registrations are revoked on disable.
  final void Function(PluginRegistrar registrar) setup;

  KernelPlugin toKernel() =>
      KernelPlugin(id: id, capabilities: capabilities, setup: setup);
}

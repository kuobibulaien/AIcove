import '../../assistant/domain/assistant_onboarding.dart';

/// Fixed id of the built-in AIcove workspace, the same on every device.
const defaultWorkspaceId = 'aicove';

/// Workspace grants of a role (ADR0087 §1). A grant is stored in the role's
/// plugin list as `workspace:<id>`, like MCP connectors, so it syncs with
/// the role; "all plugins" grants none.
abstract final class WorkspaceGrants {
  static const prefix = 'workspace:';

  static String pluginIdOf(String workspaceId) => '$prefix$workspaceId';

  static bool isGrantId(String pluginId) =>
      pluginId.startsWith(prefix) && pluginId.length > prefix.length;

  /// Workspace ids a role grants explicitly, whether or not this device has
  /// them.
  static Set<String> of(Iterable<String>? enabledPlugins) => {
    for (final id in enabledPlugins ?? const <String>[])
      if (isGrantId(id)) id.substring(prefix.length),
  };

  /// Grants a role has without an entry in its plugin list: AIcove酱 always
  /// has the built-in AIcove workspace, so factory and older installs work
  /// without rewriting her "all plugins" selection.
  static Set<String> builtInFor(String roleId) =>
      roleId == kAicoveAssistantId ? const {defaultWorkspaceId} : const {};

  /// Explicit grants plus [builtInFor].
  static Set<String> forRole(String roleId, Iterable<String>? enabledPlugins) =>
      {...of(enabledPlugins), ...builtInFor(roleId)};

  /// The single resolution rule: role grant ∩ agent preset ∩ plugin enabled
  /// ∩ present on this device. A preset ([presetAllows], null = no further
  /// limit) can only narrow.
  static Set<String> effective({
    required Set<String> roleGrants,
    required Set<String>? presetAllows,
    required bool pluginEnabled,
    required Iterable<String> localIds,
  }) {
    if (!pluginEnabled) return const {};
    final local = localIds.toSet();
    return {
      for (final id in roleGrants)
        if (local.contains(id) && (presetAllows?.contains(id) ?? true)) id,
    };
  }
}

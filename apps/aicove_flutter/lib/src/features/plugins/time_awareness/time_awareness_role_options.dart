/// Per-role time awareness options. They are stored in the role's plugin list,
/// like sticker and workspace grants, so they sync with the role. No marker
/// means the default: the model is told the current time.
abstract final class TimeAwarenessRoleOptions {
  static const noCurrentTimeId = 'time_awareness:no_current_time';

  static bool isOptionId(String pluginId) => pluginId == noCurrentTimeId;

  static bool currentTime(Iterable<String>? enabledPlugins) =>
      !(enabledPlugins?.contains(noCurrentTimeId) ?? false);

  static Set<String> withCurrentTime(Iterable<String> pluginIds, bool value) => {
    for (final id in pluginIds)
      if (!isOptionId(id)) id,
    if (!value) noCurrentTimeId,
  };
}

/// Sticker packs a role may send. A grant is stored in the role's plugin list
/// as `sticker_pack:<id>`, like workspace grants, so it syncs with the role.
/// No grant means every enabled pack.
abstract final class StickerPackGrants {
  static const prefix = 'sticker_pack:';

  static String pluginIdOf(String packId) => '$prefix$packId';

  static bool isGrantId(String pluginId) =>
      pluginId.startsWith(prefix) && pluginId.length > prefix.length;

  /// Pack ids a role grants explicitly, whether or not this device has them.
  static Set<String> of(Iterable<String>? enabledPlugins) => {
    for (final id in enabledPlugins ?? const <String>[])
      if (isGrantId(id)) id.substring(prefix.length),
  };

  /// Packs the role uses on this device: its grants that exist here, or null
  /// (every enabled pack) when it grants none of them. Pack ids are created
  /// per device, so a role synced from elsewhere falls back to all packs
  /// instead of losing stickers.
  static Set<String>? effective(
    Iterable<String>? enabledPlugins,
    Iterable<String> localPackIds,
  ) {
    final local = localPackIds.toSet();
    final granted = {
      for (final id in of(enabledPlugins))
        if (local.contains(id)) id,
    };
    return granted.isEmpty ? null : granted;
  }
}

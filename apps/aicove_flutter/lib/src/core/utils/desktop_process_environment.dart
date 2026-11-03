import 'dart:io';

String expandDesktopHome(String value, String? home) =>
    home != null &&
        (value == '~' || value.startsWith('~/') || value.startsWith('~\\'))
    ? '$home${value.substring(1)}'
    : value;

/// User PATH entries take precedence, then parent PATH, then common GUI gaps.
/// No global environment changes or login-shell initialization is performed.
/// Preserve MCP's literal variable names and case-sensitive PATH deduplication;
/// Windows native jobs normalize variable names at their launch boundary.
Map<String, String> desktopProcessEnvironment({
  Map<String, String>? parent,
  Map<String, String> overrides = const {},
  String? platform,
}) {
  final windows = (platform ?? Platform.operatingSystem) == 'windows';
  final base = parent ?? Platform.environment;
  final merged = {...base, ...overrides};
  final home = base['HOME'] ?? base['USERPROFILE'];
  final separator = windows ? ';' : ':';
  String pathOf(Map<String, String> map) =>
      map.entries
          .where((e) => e.key.toUpperCase() == 'PATH')
          .map((e) => e.value)
          .firstOrNull ??
      '';
  final paths = <String>[
    ...pathOf(overrides).split(separator),
    ...pathOf(base).split(separator),
    if (!windows) ...[
      '/opt/homebrew/bin',
      '/usr/local/bin',
      '/usr/bin',
      '/bin',
    ],
    if (home != null) ...['$home/.local/bin', '$home/.cargo/bin'],
  ];
  if (home != null) {
    final nvm = Directory('$home/.nvm/versions/node');
    if (nvm.existsSync()) {
      final versions = nvm
          .listSync()
          .whereType<Directory>()
          .where(
            (d) => RegExp(
              r'^v\d+\.\d+\.\d+$',
            ).hasMatch(d.uri.pathSegments.where((s) => s.isNotEmpty).last),
          )
          .toList();
      List<int> parts(Directory d) => d.uri.pathSegments
          .where((s) => s.isNotEmpty)
          .last
          .substring(1)
          .split('.')
          .map(int.parse)
          .toList();
      versions.sort((a, b) {
        final av = parts(a), bv = parts(b);
        for (var i = 0; i < 3; i++) {
          final compare = bv[i].compareTo(av[i]);
          if (compare != 0) return compare;
        }
        return 0;
      });
      if (versions.isNotEmpty) paths.add('${versions.first.path}/bin');
    }
  }
  merged.removeWhere((key, _) => key.toUpperCase() == 'PATH');
  merged['PATH'] = paths
      .where((p) => p.isNotEmpty)
      .map((p) => expandDesktopHome(p, home))
      .toSet()
      .join(separator);
  return merged;
}

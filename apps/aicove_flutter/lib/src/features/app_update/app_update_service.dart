/// Checks GitHub Releases of the public repository for a newer app version.
///
/// The installed version comes from `--dart-define=AICOVE_RELEASE_TAG=<tag>`,
/// injected by `tool/publish_release.py`, because `--build-name` only carries
/// the numeric core (e.g. `0.1.0`) and drops the `-test.N` suffix. Local
/// development builds have no tag and therefore never check automatically.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_logger.dart';

const kAppReleaseTag = String.fromEnvironment('AICOVE_RELEASE_TAG');
const kAppReleasesApi =
    'https://api.github.com/repos/kuobibulaien/AIcove/releases?per_page=20';
const _skippedVersionKey = 'app_update_skipped_version';

class AppRelease {
  const AppRelease({
    required this.version,
    required this.highlights,
    required this.url,
  });

  /// Version without the `v` prefix, e.g. `0.1.0-test.5`.
  final String version;
  /// One short line per change, see [releaseHighlights].
  final List<String> highlights;
  final String url;
}

/// Compares two semantic versions (leading `v` and `+build` ignored).
/// Returns null when either side is not a valid version.
int? compareReleaseVersions(String a, String b) {
  final left = _SemVer.tryParse(a);
  final right = _SemVer.tryParse(b);
  if (left == null || right == null) return null;
  return left.compareTo(right);
}

/// Condenses release notes to at most [limit] short highlights.
///
/// Takes the bullets under the `新增与改进` heading (or the first bullet list
/// when the heading is missing) and keeps each bullet up to its first clause,
/// so verification and download sections never reach the prompt.
List<String> releaseHighlights(String body, {int limit = 5}) {
  final lines = body.split('\n').map((line) => line.trim()).toList();
  final heading = lines.indexWhere((line) => line.startsWith('新增与改进'));
  final highlights = <String>[];
  for (final line in lines.skip(heading + 1)) {
    if (!line.startsWith('- ') && !line.startsWith('* ')) {
      if (highlights.isNotEmpty) break;
      continue;
    }
    final text = line.substring(2).split(RegExp('[；，。（;]')).first.trim();
    if (text.isNotEmpty) highlights.add(text);
    if (highlights.length == limit) break;
  }
  return highlights;
}

class AppUpdateService {
  AppUpdateService({http.Client? client, this.currentVersion = kAppReleaseTag})
      : _client = client ?? http.Client();

  final http.Client _client;
  final String currentVersion;

  bool get canCheck => _SemVer.tryParse(currentVersion) != null;

  /// Returns the newest published release, or null when none is usable.
  Future<AppRelease?> fetchLatest() async {
    final response = await _client.get(
      Uri.parse(kAppReleasesApi),
      headers: const {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'AIcove-update-check',
      },
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw http.ClientException('HTTP ${response.statusCode}');
    }
    final list = jsonDecode(utf8.decode(response.bodyBytes));
    if (list is! List) return null;
    AppRelease? latest;
    for (final item in list) {
      if (item is! Map || item['draft'] == true) continue;
      final tag = item['tag_name'];
      final url = item['html_url'];
      if (tag is! String || url is! String || !tag.startsWith('v')) continue;
      final version = tag.substring(1);
      if (_SemVer.tryParse(version) == null) continue;
      if (latest != null && compareReleaseVersions(version, latest.version)! <= 0) {
        continue;
      }
      final body = item['body'];
      latest = AppRelease(
        version: version,
        highlights: body is String ? releaseHighlights(body) : const [],
        url: url,
      );
    }
    return latest;
  }

  /// Returns a release newer than the installed one, or null.
  ///
  /// Automatic checks honour the skipped version and swallow errors; manual
  /// checks ignore the skipped version and rethrow so the caller can report.
  Future<AppRelease?> checkForUpdate({bool manual = false}) async {
    if (!canCheck) return null;
    try {
      final latest = await fetchLatest();
      if (latest == null) return null;
      if (compareReleaseVersions(latest.version, currentVersion)! <= 0) {
        return null;
      }
      if (!manual && await skippedVersion() == latest.version) return null;
      return latest;
    } catch (error) {
      AppLogger.warning('AppUpdate', '检查更新失败', metadata: {
        'manual': manual,
        'error': error.toString(),
      });
      if (manual) rethrow;
      return null;
    }
  }

  static Future<String?> skippedVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_skippedVersionKey);
  }

  static Future<void> skipVersion(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_skippedVersionKey, version);
  }
}

class _SemVer implements Comparable<_SemVer> {
  const _SemVer(this.core, this.pre);

  final List<int> core;
  final List<String> pre;

  static final _pattern = RegExp(
    r'^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$',
  );

  static _SemVer? tryParse(String input) {
    final match = _pattern.firstMatch(input.trim());
    if (match == null) return null;
    return _SemVer(
      [for (var i = 1; i <= 3; i++) int.parse(match.group(i)!)],
      match.group(4)?.split('.') ?? const [],
    );
  }

  @override
  int compareTo(_SemVer other) {
    for (var i = 0; i < 3; i++) {
      final diff = core[i].compareTo(other.core[i]);
      if (diff != 0) return diff;
    }
    // A release without pre-release identifiers ranks above any pre-release.
    if (pre.isEmpty || other.pre.isEmpty) {
      return (pre.isEmpty ? 1 : 0) - (other.pre.isEmpty ? 1 : 0);
    }
    for (var i = 0; i < pre.length && i < other.pre.length; i++) {
      final a = int.tryParse(pre[i]);
      final b = int.tryParse(other.pre[i]);
      final diff = a != null && b != null
          ? a.compareTo(b)
          : a != null
              ? -1
              : b != null
                  ? 1
                  : pre[i].compareTo(other.pre[i]);
      if (diff != 0) return diff;
    }
    return pre.length.compareTo(other.pre.length);
  }
}

import 'dart:convert';

import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'workspace_errors.dart';

/// Path rules shared by every platform (ADR0087 §2, plan §3): a path
/// written on one device must land unchanged on the other three.
abstract final class WorkspacePathRules {
  /// One segment, after NFC: UTF-16 code units (Windows) and UTF-8 bytes
  /// (255-byte file systems, minus room for a conflict suffix).
  static const maxSegmentUnits = 100;
  static const maxSegmentBytes = 200;

  /// Whole relative path, in UTF-16 code units: Windows' 259 usable
  /// characters minus the app data root and the workspace UUID.
  static const maxPathUnits = 150;

  /// Windows `MAX_PATH` without the terminating NUL; other platforms allow
  /// at least 1024 bytes.
  static const windowsPathLimit = 259;
  static const otherPathLimit = 1023;

  /// Host-maintained directory; file tools may read it but never write it.
  static const hostDirectory = '.aicove';

  static const _reservedNames = {
    'CON', 'PRN', 'AUX', 'NUL', //
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
  };
  static const _illegalChars = r'<>:"|?*\';

  /// Validates a relative file path and returns its NFC form.
  static String normalize(String path) {
    final raw = path;
    if (raw.isEmpty) throw const WorkspaceException.invalidPath('路径为空');
    if (raw.startsWith('/')) {
      throw const WorkspaceException.invalidPath('只接受相对路径');
    }
    final nfc = unorm.nfc(raw);
    final segments = nfc.split('/');
    for (final segment in segments) {
      checkSegment(segment);
    }
    if (nfc.length > maxPathUnits) {
      throw WorkspaceException.invalidPath(
        '路径过长（${nfc.length} 个字符，上限 $maxPathUnits）',
      );
    }
    return nfc;
  }

  /// A path for listing: empty means the workspace root.
  static String normalizeDirectory(String path) {
    var trimmed = path.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    if (trimmed.isEmpty || trimmed == '.') return '';
    return normalize(trimmed);
  }

  static void checkSegment(String segment) {
    if (segment.isEmpty) {
      throw const WorkspaceException.invalidPath('路径中有空的段');
    }
    if (segment == '.' || segment == '..') {
      throw const WorkspaceException.invalidPath('路径不能包含 . 或 ..');
    }
    for (final unit in segment.codeUnits) {
      if (unit < 0x20 || _illegalChars.contains(String.fromCharCode(unit))) {
        throw WorkspaceException.invalidPath(
          '文件名「$segment」含有不允许的字符（控制字符或 <>:"|?*\\）',
        );
      }
    }
    if (segment.endsWith(' ') || segment.endsWith('.')) {
      throw WorkspaceException.invalidPath('文件名「$segment」不能以空格或点结尾');
    }
    final stem = segment.split('.').first.toUpperCase().trimRight();
    if (_reservedNames.contains(stem)) {
      throw WorkspaceException.invalidPath('「$segment」是 Windows 保留名');
    }
    if (segment.length > maxSegmentUnits) {
      throw WorkspaceException.invalidPath(
        '文件名过长（${segment.length} 个字符，上限 $maxSegmentUnits）',
      );
    }
    final bytes = utf8.encode(segment).length;
    if (bytes > maxSegmentBytes) {
      throw WorkspaceException.invalidPath(
        '文件名过长（$bytes 字节，上限 $maxSegmentBytes）',
      );
    }
  }

  /// Case-insensitive key for collision checks.
  static String fold(String normalizedPath) => normalizedPath.toLowerCase();

  /// True when [normalizedPath] is inside the host directory.
  static bool isHostPath(String normalizedPath) =>
      normalizedPath == hostDirectory ||
      normalizedPath.startsWith('$hostDirectory/');

  /// Whether a workspace rooted at [workspaceRoot] leaves the full relative
  /// path budget on this platform; creation and import stop otherwise.
  static bool rootFits(String workspaceRoot, {required bool windows}) =>
      (windows ? workspaceRoot.length : utf8.encode(workspaceRoot).length) +
          1 +
          (windows ? maxPathUnits : maxPathUnits * 3) <=
      (windows ? windowsPathLimit : otherPathLimit);
}

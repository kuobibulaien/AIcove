import 'package:path/path.dart' as p;

class MimeUtils {
  const MimeUtils._();

  static String guessGenericMimeType(
    String path, {
    String fallback = 'application/octet-stream',
  }) {
    switch (_extensionOf(path)) {
      case 'txt':
      case 'log':
      case 'md':
      case 'markdown':
        return 'text/plain';
      case 'json':
        return 'application/json';
      case 'yaml':
      case 'yml':
        return 'application/x-yaml';
      case 'csv':
        return 'text/csv';
      case 'pdf':
        return 'application/pdf';
      default:
        return fallback;
    }
  }

  static String guessVideoMimeType(
    String path, {
    String fallback = 'video/mp4',
  }) {
    switch (_extensionOf(path)) {
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'webm':
        return 'video/webm';
      case 'mkv':
        return 'video/x-matroska';
      case 'avi':
        return 'video/x-msvideo';
      default:
        return fallback;
    }
  }

  static String guessImageMimeType(
    String path, {
    String fallback = 'image/jpeg',
  }) {
    switch (_extensionOf(path)) {
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'gif':
        return 'image/gif';
      case 'bmp':
        return 'image/bmp';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      default:
        return fallback;
    }
  }

  static String guessAttachmentMimeType(
    String path, {
    String fallback = 'application/octet-stream',
  }) {
    final ext = _extensionOf(path);
    switch (ext) {
      case 'png':
      case 'webp':
      case 'gif':
      case 'bmp':
      case 'jpg':
      case 'jpeg':
        return guessImageMimeType(path, fallback: fallback);
      case 'wav':
      case 'mp3':
      case 'm4a':
      case 'ogg':
      case 'opus':
      case 'pcm':
        return guessAudioMimeType(path, fallback: fallback);
      case 'mp4':
      case 'mov':
      case 'webm':
      case 'mkv':
      case 'avi':
        return guessVideoMimeType(path, fallback: fallback);
      default:
        return guessGenericMimeType(path, fallback: fallback);
    }
  }

  static String guessAudioMimeType(
    String path, {
    String fallback = 'audio/mpeg',
  }) {
    switch (_extensionOf(path)) {
      case 'wav':
        return 'audio/wav';
      case 'mp3':
        return 'audio/mpeg';
      case 'm4a':
        return 'audio/mp4';
      case 'ogg':
        return 'audio/ogg';
      case 'opus':
        return 'audio/opus';
      case 'pcm':
        return 'audio/pcm';
      default:
        return fallback;
    }
  }

  static String? normalizeContentType(String? rawContentType) {
    final value = rawContentType?.trim();
    if (value == null || value.isEmpty) return null;
    final mime = value.split(';').first.trim().toLowerCase();
    if (mime.isEmpty) return null;
    return mime;
  }

  static bool isAudioMimeType(String? mimeType) {
    final normalized = normalizeContentType(mimeType);
    return normalized != null && normalized.startsWith('audio/');
  }

  static bool isVideoMimeType(String? mimeType) {
    final normalized = normalizeContentType(mimeType);
    return normalized != null && normalized.startsWith('video/');
  }

  static String resolveAudioMimeType(
    String rawContentType,
    List<int> bytes, {
    String fallback = 'application/octet-stream',
  }) {
    bool startsWithAscii(String s) {
      if (bytes.length < s.length) return false;
      for (var i = 0; i < s.length; i++) {
        if (bytes[i] != s.codeUnitAt(i)) return false;
      }
      return true;
    }

    bool looksLikeWav() {
      return startsWithAscii('RIFF') &&
          bytes.length >= 12 &&
          String.fromCharCodes(bytes.sublist(8, 12)) == 'WAVE';
    }

    bool looksLikeOgg() => startsWithAscii('OggS');

    bool looksLikeMp3() {
      if (startsWithAscii('ID3')) return true;
      if (bytes.length < 2) return false;
      return bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0;
    }

    final contentType = normalizeContentType(rawContentType) ?? '';
    if (contentType.contains('audio/wav') ||
        contentType.contains('audio/x-wav')) {
      return 'audio/wav';
    }
    if (contentType.contains('audio/ogg')) return 'audio/ogg';
    if (contentType.contains('audio/mpeg') ||
        contentType.contains('audio/mp3')) {
      return 'audio/mpeg';
    }
    if (contentType.contains('audio/')) return contentType;

    if (looksLikeWav()) return 'audio/wav';
    if (looksLikeOgg()) return 'audio/ogg';
    if (looksLikeMp3()) return 'audio/mpeg';

    return fallback;
  }

  static String _extensionOf(String path) =>
      p.extension(path).replaceFirst('.', '').toLowerCase();
}

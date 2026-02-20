import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../app_logger.dart';

/// On Windows, route network requests through user proxy settings by default.
/// Priority: direct/bypass first, then environment variables, finally system proxy.
Future<void> installWindowsProxyHttpOverrides() async {
  if (kIsWeb || !Platform.isWindows) return;

  final env = Platform.environment;
  final systemProxy = await _WindowsSystemProxyConfig.load();
  HttpOverrides.global = _WindowsProxyHttpOverrides(
    environment: env,
    systemProxy: systemProxy,
  );

  if (systemProxy == null) {
    AppLogger.info(
      'Network',
      'Windows proxy override enabled (env proxy or direct when no system proxy)',
    );
    return;
  }

  AppLogger.info(
    'Network',
    'Windows proxy override enabled (system proxy active)',
    metadata: <String, dynamic>{
      'http': systemProxy.httpProxy,
      'https': systemProxy.httpsProxy,
      'all': systemProxy.allProxy,
      'hasBypassRules': systemProxy.bypassPatterns.isNotEmpty,
    },
  );
}

class _WindowsProxyHttpOverrides extends HttpOverrides {
  _WindowsProxyHttpOverrides({
    required this.environment,
    required this.systemProxy,
  });

  final Map<String, String> environment;
  final _WindowsSystemProxyConfig? systemProxy;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (uri) {
      if (_shouldAlwaysBypass(uri)) {
        return 'DIRECT';
      }

      final systemDecision = systemProxy?.findProxy(uri);
      if (systemDecision != null && systemDecision.toUpperCase() == 'DIRECT') {
        return 'DIRECT';
      }

      final envProxy = _findProxyFromEnvironment(uri, environment);
      if (envProxy.toUpperCase() != 'DIRECT') {
        return envProxy;
      }
      return systemDecision ?? 'DIRECT';
    };
    return client;
  }

  bool _shouldAlwaysBypass(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return false;

    // Always bypass proxy for loopback and private-link targets.
    if (host == 'localhost' ||
        host == '::1' ||
        host == '0:0:0:0:0:0:0:1' ||
        host.startsWith('127.')) {
      return true;
    }

    final ip = InternetAddress.tryParse(host);
    if (ip == null) return false;
    if (ip.isLoopback) return true;
    if (ip.type != InternetAddressType.IPv4) return false;

    final bytes = ip.rawAddress;
    if (bytes.length < 2) return false;

    final first = bytes[0];
    final second = bytes[1];
    if (first == 10) return true; // 10.0.0.0/8
    if (first == 192 && second == 168) return true; // 192.168.0.0/16
    if (first == 172 && second >= 16 && second <= 31) return true; // 172.16/12
    if (first == 169 && second == 254) return true; // link-local
    return false;
  }

  String _findProxyFromEnvironment(Uri uri, Map<String, String> env) {
    try {
      final proxy = HttpClient.findProxyFromEnvironment(uri, environment: env);
      final normalized = proxy.trim();
      if (normalized.isEmpty) return 'DIRECT';
      return normalized;
    } catch (_) {
      return 'DIRECT';
    }
  }
}

class _WindowsSystemProxyConfig {
  const _WindowsSystemProxyConfig({
    this.httpProxy,
    this.httpsProxy,
    this.allProxy,
    this.socksProxy,
    this.bypassPatterns = const <String>[],
  });

  final String? httpProxy;
  final String? httpsProxy;
  final String? allProxy;
  final String? socksProxy;
  final List<String> bypassPatterns;

  static Future<_WindowsSystemProxyConfig?> load() async {
    final settings = await _queryInternetSettings();
    if (settings.isEmpty) return null;

    final enabled = _parseDword(settings['ProxyEnable']);
    if (!enabled) return null;

    final serverRaw = (settings['ProxyServer'] ?? '').trim();
    if (serverRaw.isEmpty) return null;

    final parsedServer = _parseProxyServer(serverRaw);
    if (parsedServer.isEmpty) return null;

    final bypassRaw = (settings['ProxyOverride'] ?? '').trim();
    return _WindowsSystemProxyConfig(
      httpProxy: parsedServer['http'],
      httpsProxy: parsedServer['https'],
      allProxy: parsedServer['all'],
      socksProxy: parsedServer['socks'],
      bypassPatterns: _parseBypassPatterns(bypassRaw),
    );
  }

  static Future<Map<String, String>> _queryInternetSettings() async {
    try {
      final result = await Process.run(
        'reg',
        <String>[
          'query',
          r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
        ],
        runInShell: true,
      );
      if (result.exitCode != 0) return const <String, String>{};

      final output = result.stdout?.toString() ?? '';
      if (output.trim().isEmpty) return const <String, String>{};

      final values = <String, String>{};
      final lines = output.split(RegExp(r'\r?\n'));
      for (final line in lines) {
        if (!line.contains('REG_')) continue;
        final parts = line.trim().split(RegExp(r'\s{2,}'));
        if (parts.length < 3) continue;
        final key = parts[0].trim();
        final value = parts.sublist(2).join(' ').trim();
        values[key] = value;
      }
      return values;
    } catch (e) {
      AppLogger.warning('Network', 'Failed to read Windows proxy config: $e');
      return const <String, String>{};
    }
  }

  static bool _parseDword(String? value) {
    if (value == null) return false;
    final trimmed = value.trim().toLowerCase();
    if (trimmed == '1') return true;
    if (trimmed.startsWith('0x')) {
      final parsed = int.tryParse(trimmed.substring(2), radix: 16);
      return parsed == 1;
    }
    return false;
  }

  static Map<String, String> _parseProxyServer(String raw) {
    final result = <String, String>{};
    for (final segment in raw.split(';')) {
      final part = segment.trim();
      if (part.isEmpty) continue;

      if (part.contains('=')) {
        final idx = part.indexOf('=');
        final kindRaw = part.substring(0, idx).trim().toLowerCase();
        final kind = kindRaw.startsWith('socks') ? 'socks' : kindRaw;
        final endpoint = _normalizeProxyEndpoint(
          part.substring(idx + 1),
          forceSocks: kind == 'socks',
        );
        if (endpoint == null) continue;
        if (kind == 'http' || kind == 'https' || kind == 'socks') {
          result[kind] = endpoint;
        }
        continue;
      }

      final endpoint = _normalizeProxyEndpoint(part);
      if (endpoint == null) continue;
      result['all'] = endpoint;
    }
    return result;
  }

  static String? _normalizeProxyEndpoint(
    String raw, {
    bool forceSocks = false,
  }) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    final parsedUri = Uri.tryParse(trimmed);
    if (parsedUri != null && parsedUri.hasScheme && parsedUri.host.isNotEmpty) {
      final hostPort = _formatHostPort(parsedUri.host, parsedUri.port);
      if (hostPort == null) return null;
      if (forceSocks || parsedUri.scheme.toLowerCase().startsWith('socks')) {
        return 'SOCKS $hostPort';
      }
      return 'PROXY $hostPort';
    }

    final noCredential = _stripCredential(trimmed);
    if (noCredential.isEmpty) return null;

    final upper = noCredential.toUpperCase();
    if (upper.startsWith('PROXY ') || upper.startsWith('SOCKS ')) {
      return noCredential;
    }
    return forceSocks ? 'SOCKS $noCredential' : 'PROXY $noCredential';
  }

  static String _stripCredential(String value) {
    final v = value.trim();
    final at = v.lastIndexOf('@');
    if (at < 0) return v;
    return v.substring(at + 1).trim();
  }

  static String? _formatHostPort(String host, int port) {
    final h = host.trim();
    if (h.isEmpty) return null;
    if (port > 0) return '$h:$port';
    return h;
  }

  static List<String> _parseBypassPatterns(String raw) {
    if (raw.trim().isEmpty) return const <String>[];
    return raw
        .split(';')
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  String findProxy(Uri uri) {
    final host = uri.host.toLowerCase();
    if (_isLoopbackHost(host) || _shouldBypass(host)) {
      return 'DIRECT';
    }

    final scheme = uri.scheme.toLowerCase();
    final endpoint = switch (scheme) {
      'https' => httpsProxy ?? allProxy ?? httpProxy ?? socksProxy,
      'http' => httpProxy ?? allProxy ?? httpsProxy ?? socksProxy,
      _ => allProxy ?? httpsProxy ?? httpProxy ?? socksProxy,
    };

    if (endpoint == null || endpoint.isEmpty) return 'DIRECT';
    return '$endpoint; DIRECT';
  }

  bool _isLoopbackHost(String host) {
    return host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1' ||
        host.startsWith('127.');
  }

  bool _shouldBypass(String host) {
    for (final rawPattern in bypassPatterns) {
      final pattern = rawPattern.trim();
      if (pattern.isEmpty) continue;

      if (pattern == '<local>' && !host.contains('.')) {
        return true;
      }

      if (pattern.startsWith('<') && pattern.endsWith('>')) {
        continue;
      }

      if (_wildcardMatch(host, pattern)) {
        return true;
      }
    }
    return false;
  }

  bool _wildcardMatch(String host, String pattern) {
    if (!pattern.contains('*') && !pattern.contains('?')) {
      return host == pattern || host.endsWith('.$pattern');
    }

    final escaped =
        RegExp.escape(pattern).replaceAll(r'\*', '.*').replaceAll(r'\?', '.');
    final reg = RegExp('^$escaped\$');
    return reg.hasMatch(host);
  }
}

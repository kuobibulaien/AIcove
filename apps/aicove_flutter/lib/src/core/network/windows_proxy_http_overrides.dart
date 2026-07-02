import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import '../app_logger.dart';

const MethodChannel _systemProxyChannel =
    MethodChannel('com.example.aicove_flutter/system_proxy');

/// Install platform-aware proxy override before any network client is created.
///
/// Coverage:
///   - Windows  → read from registry (Internet Settings)
///   - Android  → MethodChannel + system properties + local port probe
///   - iOS/macOS/Linux → environment variables (Dart built-in)
///
/// Priority when resolving each request:
///   1. bypass (loopback / private-link)
///   2. system proxy (per platform)
///   3. environment variables (http_proxy / https_proxy / no_proxy)
///   4. DIRECT
Future<void> installProxyHttpOverrides() async {
  if (kIsWeb) return;

  final env = Platform.environment;
  _SystemProxyConfig? systemProxy;
  try {
    systemProxy = await _SystemProxyConfig.load();
  } catch (e) {
    AppLogger.warning('Network', 'Failed to load system proxy: $e');
  }

  HttpOverrides.global = _ProxyHttpOverrides(
    environment: env,
    systemProxy: systemProxy,
  );

  final platform = _currentPlatformName();
  if (systemProxy == null) {
    AppLogger.info(
      'Network',
      '$platform proxy override installed (no system proxy detected → env / direct)',
    );
    return;
  }

  AppLogger.info(
    'Network',
    '$platform proxy override installed (system proxy active)',
    metadata: <String, dynamic>{
      'http': systemProxy.httpProxy,
      'https': systemProxy.httpsProxy,
      'all': systemProxy.allProxy,
      'hasBypassRules': systemProxy.bypassPatterns.isNotEmpty,
    },
  );
}

@Deprecated('Use installProxyHttpOverrides instead.')
Future<void> installWindowsProxyHttpOverrides() async {
  await installProxyHttpOverrides();
}

String _currentPlatformName() {
  if (Platform.isWindows) return 'Windows';
  if (Platform.isAndroid) return 'Android';
  if (Platform.isIOS) return 'iOS';
  if (Platform.isMacOS) return 'macOS';
  if (Platform.isLinux) return 'Linux';
  return 'Unknown';
}

// ---------------------------------------------------------------------------
// HttpOverrides — unified for all platforms
// ---------------------------------------------------------------------------

class _ProxyHttpOverrides extends HttpOverrides {
  _ProxyHttpOverrides({
    required this.environment,
    required this.systemProxy,
  });

  final Map<String, String> environment;
  final _SystemProxyConfig? systemProxy;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (uri) {
      if (_shouldAlwaysBypass(uri)) {
        return 'DIRECT';
      }

      // 优先级 1：系统代理
      final systemDecision = systemProxy?.findProxy(uri);
      if (systemDecision != null && systemDecision.toUpperCase() == 'DIRECT') {
        return 'DIRECT';
      }

      // 优先级 2：环境变量代理
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

// ---------------------------------------------------------------------------
// _SystemProxyConfig — platform-specific proxy detection
// ---------------------------------------------------------------------------

class _SystemProxyConfig {
  // 常见 Android 本地代理端口（Clash / V2Ray / Shadowsocks 等）。
  static const List<int> _androidLocalProxyPorts = <int>[
    7890,
    7897,
    1080,
    10808,
    10809,
    20171,
  ];

  const _SystemProxyConfig({
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

  /// Load system proxy config using the best available method per platform.
  static Future<_SystemProxyConfig?> load() async {
    try {
      if (Platform.isWindows) {
        return await _loadFromWindowsRegistry();
      }
      if (Platform.isAndroid) {
        return await _loadFromMobile(useMethodChannel: true);
      }
      if (Platform.isIOS) {
        return await _loadFromMobile(useMethodChannel: false);
      }
      // macOS / Linux → Dart's built-in env proxy (http_proxy/https_proxy) is
      // sufficient; no extra detection needed.
    } catch (e) {
      AppLogger.warning('Network', 'Failed to load system proxy config: $e');
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Mobile (Android / iOS) — dual detection for maximum reliability
  // -------------------------------------------------------------------------

  static Future<_SystemProxyConfig?> _loadFromMobile({
    required bool useMethodChannel,
  }) async {
    // Method 1: MethodChannel (Android only, reads ConnectivityManager + sysprops)
    if (useMethodChannel) {
      try {
        final config = await _loadFromAndroidMethodChannel();
        if (config != null) {
          AppLogger.info('Network', 'Proxy detected via MethodChannel',
              metadata: {'all': config.allProxy});
          return config;
        }
      } catch (e) {
        AppLogger.warning(
            'Network', 'MethodChannel proxy detection failed: $e');
      }

      // Method 2: 本地端口探测（用于未开启系统代理但本地代理服务已启动的场景）
      final localConfig = await _loadFromAndroidLocalProxyProbe();
      if (localConfig != null) {
        AppLogger.info(
          'Network',
          'Proxy detected via localhost probe',
          metadata: {'all': localConfig.allProxy},
        );
        return localConfig;
      }
    }

    AppLogger.info('Network',
        '${Platform.isAndroid ? "Android" : "iOS"}: no system proxy detected');
    return null;
  }

  /// Read proxy via the custom MethodChannel on Android.
  static Future<_SystemProxyConfig?> _loadFromAndroidMethodChannel() async {
    try {
      final settings = await _systemProxyChannel
          .invokeMapMethod<String, dynamic>('getSystemProxy');
      if (settings == null || settings.isEmpty) return null;

      final host = settings['host']?.toString().trim() ?? '';
      final port = _parseInt(settings['port']);
      final exclusionRaw = settings['exclusionList']?.toString() ?? '';
      final pacUrl = settings['pacUrl']?.toString().trim() ?? '';

      if (host.isEmpty || port == null || port <= 0) {
        if (pacUrl.isNotEmpty) {
          AppLogger.warning(
            'Network',
            'Android system proxy uses PAC; PAC evaluation not implemented',
            metadata: <String, dynamic>{'pacUrl': pacUrl},
          );
        }
        return null;
      }

      final endpoint = _normalizeProxyEndpoint('$host:$port');
      if (endpoint == null) return null;

      return _SystemProxyConfig(
        allProxy: endpoint,
        bypassPatterns: _parseBypassPatterns(exclusionRaw),
      );
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      AppLogger.warning(
        'Network',
        'Android MethodChannel proxy read failed: ${e.message}',
      );
      return null;
    }
  }

  static Future<_SystemProxyConfig?> _loadFromAndroidLocalProxyProbe() async {
    for (final port in _androidLocalProxyPorts) {
      final reachable = await _canConnectLocalPort(port);
      if (!reachable) continue;

      final endpoint = _normalizeProxyEndpoint('127.0.0.1:$port');
      if (endpoint == null) continue;

      return _SystemProxyConfig(allProxy: endpoint);
    }
    return null;
  }

  static Future<bool> _canConnectLocalPort(int port) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 250),
      );
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        await socket?.close();
      } catch (_) {}
    }
  }

  // -------------------------------------------------------------------------
  // Windows — read from registry
  // -------------------------------------------------------------------------

  static Future<_SystemProxyConfig?> _loadFromWindowsRegistry() async {
    final settings = await _queryInternetSettings();
    if (settings.isEmpty) return null;

    final enabled = _parseDword(settings['ProxyEnable']);
    if (!enabled) return null;

    final serverRaw = (settings['ProxyServer'] ?? '').trim();
    if (serverRaw.isEmpty) return null;

    final parsedServer = _parseProxyServer(serverRaw);
    if (parsedServer.isEmpty) return null;

    final bypassRaw = (settings['ProxyOverride'] ?? '').trim();
    return _SystemProxyConfig(
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

  // -------------------------------------------------------------------------
  // Proxy resolution for each request
  // -------------------------------------------------------------------------

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
      if (host == pattern) return true;
      if (pattern.startsWith('.')) return host.endsWith(pattern);
      return host.endsWith('.$pattern');
    }

    final escaped =
        RegExp.escape(pattern).replaceAll(r'\*', '.*').replaceAll(r'\?', '.');
    final reg = RegExp('^$escaped\$');
    return reg.hasMatch(host);
  }

  // -------------------------------------------------------------------------
  // Parsing helpers
  // -------------------------------------------------------------------------

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

  static int? _parseInt(Object? value) {
    if (value == null) return null;
    if (value is int) return value;
    return int.tryParse(value.toString());
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
        .split(RegExp(r'[;,|]'))
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }
}

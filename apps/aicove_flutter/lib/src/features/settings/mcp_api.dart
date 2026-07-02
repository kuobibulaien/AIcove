import '../../core/api_client.dart';

class McpDelegateConfigDto {
  final bool enabled;
  final String? provider;
  final String? model;
  final String? apiBase;
  final String prompt;

  const McpDelegateConfigDto({
    required this.enabled,
    this.provider,
    this.model,
    this.apiBase,
    this.prompt = '',
  });

  factory McpDelegateConfigDto.fromJson(Map<String, dynamic> json) {
    return McpDelegateConfigDto(
      enabled: (json['enabled'] as bool?) ?? false,
      provider: _readString(json['provider']),
      model: _readString(json['model']),
      apiBase: _readString(json['api_base']) ?? _readString(json['apiBase']),
      prompt: _readString(json['prompt']) ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'provider': provider,
        'model': model,
        'api_base': apiBase,
        'apiBase': apiBase,
        'prompt': prompt,
      };

  McpDelegateConfigDto copyWith({
    bool? enabled,
    String? provider,
    String? model,
    String? apiBase,
    String? prompt,
  }) {
    return McpDelegateConfigDto(
      enabled: enabled ?? this.enabled,
      provider: provider ?? this.provider,
      model: model ?? this.model,
      apiBase: apiBase ?? this.apiBase,
      prompt: prompt ?? this.prompt,
    );
  }
}

class McpConfigDto {
  final bool enabled;
  final List<String> enabledTools;
  final McpDelegateConfigDto delegate;

  const McpConfigDto({
    required this.enabled,
    required this.enabledTools,
    required this.delegate,
  });

  factory McpConfigDto.fromJson(Map<String, dynamic> json) {
    final tools = (json['enabled_tools'] ??
        json['enabledTools'] ??
        const <dynamic>[]) as List<dynamic>;
    return McpConfigDto(
      enabled: (json['enabled'] as bool?) ?? false,
      enabledTools:
          tools.map((e) => e.toString()).where((e) => e.isNotEmpty).toList(),
      delegate: McpDelegateConfigDto.fromJson(
        (json['delegate'] as Map<String, dynamic>?) ??
            const <String, dynamic>{},
      ),
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'enabled_tools': enabledTools,
        'enabledTools': enabledTools,
        'delegate': delegate.toJson(),
      };

  McpConfigDto copyWith({
    bool? enabled,
    List<String>? enabledTools,
    McpDelegateConfigDto? delegate,
  }) {
    return McpConfigDto(
      enabled: enabled ?? this.enabled,
      enabledTools: enabledTools ?? List<String>.from(this.enabledTools),
      delegate: delegate ?? this.delegate,
    );
  }
}

class McpToolInfoDto {
  final String id;
  final String description;
  final bool enabled;

  const McpToolInfoDto({
    required this.id,
    required this.description,
    required this.enabled,
  });

  factory McpToolInfoDto.fromJson(Map<String, dynamic> json) {
    final id = _readString(json['id']) ??
        _readString(json['tool_id']) ??
        _readString(json['toolId']) ??
        _readString(json['name']) ??
        _readString(json['tool_name']) ??
        _readString(json['toolName']) ??
        '';
    final description =
        _readString(json['description']) ?? _readString(json['title']) ?? '';
    return McpToolInfoDto(
      id: id,
      description: description,
      // Standard MCP tools/list usually does not include "enabled".
      enabled: _readBool(
        json['enabled'] ?? json['is_enabled'] ?? json['isEnabled'],
        fallback: true,
      ),
    );
  }

  McpToolInfoDto copyWith({bool? enabled}) {
    return McpToolInfoDto(
      id: id,
      description: description,
      enabled: enabled ?? this.enabled,
    );
  }
}

class McpConfigResponseDto {
  final McpConfigDto config;
  final List<McpToolInfoDto> tools;

  const McpConfigResponseDto({required this.config, required this.tools});

  factory McpConfigResponseDto.fromJson(Map<String, dynamic> json) {
    final root = _readMap(json['result']) ?? json;

    final configJson = (_readMap(root['config']) ??
            _readMap(root['mcp_config']) ??
            const <String, dynamic>{})
        .cast<String, dynamic>();

    final toolsRaw = _extractTools(root);
    final toolsJson = toolsRaw
        .map(McpToolInfoDto.fromJson)
        .where((t) => t.id.isNotEmpty)
        .toList();

    final fallbackEnabledTools = toolsJson
        .where((t) => t.enabled)
        .map((t) => t.id)
        .toList(growable: false);

    final parsedConfig = configJson.isEmpty
        ? McpConfigDto(
            enabled: fallbackEnabledTools.isNotEmpty,
            enabledTools: fallbackEnabledTools,
            delegate: const McpDelegateConfigDto(enabled: false),
          )
        : McpConfigDto.fromJson(configJson);

    final normalizedConfig = parsedConfig.copyWith(
      enabled: configJson.isEmpty
          ? parsedConfig.enabled
          : _readBool(configJson['enabled'], fallback: parsedConfig.enabled),
      enabledTools: parsedConfig.enabledTools.isNotEmpty
          ? parsedConfig.enabledTools
          : fallbackEnabledTools,
    );

    return McpConfigResponseDto(
      config: normalizedConfig,
      tools: toolsJson,
    );
  }

  static List<Map<String, dynamic>> _extractTools(Map<String, dynamic> root) {
    final directTools = _readMapList(root['tools']);
    if (directTools.isNotEmpty) return directTools;

    final itemTools = _readMapList(root['items']);
    if (itemTools.isNotEmpty) return itemTools;

    final result = _readMap(root['result']);
    if (result != null) {
      final nestedTools = _readMapList(result['tools']);
      if (nestedTools.isNotEmpty) return nestedTools;
      final nestedItems = _readMapList(result['items']);
      if (nestedItems.isNotEmpty) return nestedItems;
    }

    return const <Map<String, dynamic>>[];
  }
}

class McpToolTestResultDto {
  final bool ok;
  final String message;

  const McpToolTestResultDto({required this.ok, required this.message});

  factory McpToolTestResultDto.fromJson(Map<String, dynamic> json) {
    return McpToolTestResultDto(
      ok: (json['ok'] as bool?) ?? false,
      message: _readString(json['message']) ?? '',
    );
  }
}

class TtsToolConfigDto {
  final String apiKey;
  final String promptAudioUrl;
  final String promptText;
  final double? speed;
  final String requestUrl;

  const TtsToolConfigDto({
    required this.apiKey,
    required this.promptAudioUrl,
    required this.promptText,
    this.speed,
    required this.requestUrl,
  });

  factory TtsToolConfigDto.fromJson(Map<String, dynamic> json) {
    double? parseSpeed(dynamic value) {
      if (value == null || value == '') return null;
      final parsed = double.tryParse(value.toString());
      if (parsed == null || parsed <= 0) return null;
      return parsed;
    }

    return TtsToolConfigDto(
      apiKey: _readString(json['api_key']) ?? _readString(json['apiKey']) ?? '',
      promptAudioUrl: _readString(json['prompt_audio_url']) ??
          _readString(json['promptAudioUrl']) ??
          '',
      promptText: _readString(json['prompt_text']) ??
          _readString(json['promptText']) ??
          '',
      speed: parseSpeed(json['speed']),
      requestUrl: _readString(json['request_url']) ??
          _readString(json['requestUrl']) ??
          '',
    );
  }

  Map<String, dynamic> toJson() => {
        'api_key': apiKey,
        'apiKey': apiKey,
        'prompt_audio_url': promptAudioUrl,
        'promptAudioUrl': promptAudioUrl,
        'prompt_text': promptText,
        'promptText': promptText,
        'speed': speed,
        'request_url': requestUrl,
        'requestUrl': requestUrl,
      };
}

class TtsPresetDto {
  final String id;
  final String name;
  final bool builtin;
  final TtsToolConfigDto config;

  const TtsPresetDto(
      {required this.id,
      required this.name,
      required this.builtin,
      required this.config});

  factory TtsPresetDto.fromJson(Map<String, dynamic> json) {
    return TtsPresetDto(
      id: _readString(json['id']) ?? '',
      name: _readString(json['name']) ?? '未命名预设',
      builtin: json['builtin'] == true,
      config: TtsToolConfigDto.fromJson(
          (json['config'] as Map<String, dynamic>? ??
              const <String, dynamic>{})),
    );
  }
}

class TtsToolConfigResponseDto {
  final TtsToolConfigDto config;
  final TtsToolConfigDto defaults;
  final List<TtsPresetDto> presets;

  const TtsToolConfigResponseDto(
      {required this.config, required this.defaults, required this.presets});

  factory TtsToolConfigResponseDto.fromJson(Map<String, dynamic> json) {
    final cfg =
        (json['config'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    final defs = (json['defaults'] as Map<String, dynamic>?) ??
        const <String, dynamic>{};
    final presetsRaw = (json['presets'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(TtsPresetDto.fromJson)
        .toList();
    return TtsToolConfigResponseDto(
      config: TtsToolConfigDto.fromJson(cfg),
      defaults: TtsToolConfigDto.fromJson(defs),
      presets: presetsRaw,
    );
  }
}

class TtsToolTestResponseDto {
  final String audioUrl;
  final bool cached;

  const TtsToolTestResponseDto({required this.audioUrl, required this.cached});

  factory TtsToolTestResponseDto.fromJson(Map<String, dynamic> json) {
    return TtsToolTestResponseDto(
      audioUrl: _readString(json['audio_url']) ?? '',
      cached: json['cached'] == true,
    );
  }
}

class McpApi {
  static const Duration mobileConfigCacheTtl = Duration(minutes: 2);
  static const String defaultJsonRpcPath = '/mcp/rpc';

  final ApiClient _api;
  McpApi([ApiClient? api]) : _api = api ?? ApiClient();

  Future<McpConfigResponseDto> fetchConfig({
    bool allowStandardFallback = true,
  }) async {
    try {
      final res = await _api.getJson('/mcp/config');
      return McpConfigResponseDto.fromJson(res);
    } catch (e) {
      if (!allowStandardFallback) rethrow;
      // Fast-fail on transport-level errors (connection refused/timeout/etc.)
      // to avoid spending extra time on equivalent fallback endpoints.
      if (_isTransportUnavailableError(e)) rethrow;
      final fallback = await _fetchConfigFromStandardMcp();
      if (fallback != null) return fallback;
      rethrow;
    }
  }

  Future<McpConfigResponseDto> updateConfig(McpConfigDto config) async {
    final res = await _api.putJson('/mcp/config', config.toJson());
    return McpConfigResponseDto.fromJson(res);
  }

  Future<McpToolTestResultDto> testTool(String toolId) async {
    final res = await _api.postJson('/mcp/tools/$toolId:test', {});
    return McpToolTestResultDto.fromJson(res);
  }

  /// JSON-RPC 2.0 wrapper for standard MCP gateway endpoints.
  Future<Map<String, dynamic>> callJsonRpc({
    required String method,
    Map<String, dynamic>? params,
    String path = defaultJsonRpcPath,
    String? id,
  }) async {
    final requestId =
        id ?? 'mobile-${DateTime.now().microsecondsSinceEpoch.toString()}';
    final body = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': requestId,
      'method': method,
      if (params != null) 'params': params,
    };

    final res = await _api.postJson(path, body);
    final error = _readMap(res['error']);
    if (error != null) {
      final code = error['code'];
      final message = _readString(error['message']) ?? 'unknown error';
      throw StateError('MCP JSON-RPC $method failed (code=$code): $message');
    }
    return res;
  }

  Future<TtsToolConfigResponseDto> fetchTtsConfig() async {
    final res = await _api.getJson('/mcp/tts/config');
    return TtsToolConfigResponseDto.fromJson(res);
  }

  Future<TtsToolConfigResponseDto> updateTtsConfig(TtsToolConfigDto dto) async {
    final res = await _api.putJson('/mcp/tts/config', dto.toJson());
    return TtsToolConfigResponseDto.fromJson(res);
  }

  Future<TtsToolConfigResponseDto> createTtsPreset(
      {required String name, required TtsToolConfigDto dto}) async {
    final body = {
      'name': name,
      ...dto.toJson(),
    };
    final res = await _api.postJson('/mcp/tts/presets', body);
    return TtsToolConfigResponseDto.fromJson(res);
  }

  Future<TtsToolConfigResponseDto> deleteTtsPreset(String presetId) async {
    final res = await _api.deleteJson('/mcp/tts/presets/$presetId');
    return TtsToolConfigResponseDto.fromJson(res);
  }

  Future<TtsToolTestResponseDto> testTts(String text) async {
    final res = await _api.postJson('/mcp/tts/test', {'text': text});
    return TtsToolTestResponseDto.fromJson(res);
  }

  Future<Map<String, String>> getPrompts() async {
    final res = await _api.getJson('/mcp/prompts');
    final items = (res['items'] as Map<String, dynamic>?);
    final map = <String, String>{};
    if (items != null) {
      items.forEach((k, v) => map[k] = (v ?? '').toString());
    }
    return map;
  }

  Future<Map<String, String>> updatePrompts(Map<String, String> items) async {
    final res = await _api.putJson('/mcp/prompts', {'items': items});
    final out = <String, String>{};
    final data = (res['items'] as Map<String, dynamic>?);
    if (data != null) {
      data.forEach((k, v) => out[k] = (v ?? '').toString());
    }
    return out;
  }

  Future<McpConfigResponseDto?> _fetchConfigFromStandardMcp() async {
    // Path 1: JSON-RPC MCP gateway.
    try {
      await _tryInitializeStandardMcp();
      final toolsList = await callJsonRpc(
        method: 'tools/list',
        params: const <String, dynamic>{},
      );
      return McpConfigResponseDto.fromJson(toolsList);
    } catch (e) {
      if (_isTransportUnavailableError(e)) return null;
      // Ignore and continue to non-RPC fallback.
    }

    // Path 2: Non-standard but common fallback endpoint.
    try {
      final res = await _api.getJson('/mcp/tools');
      return McpConfigResponseDto.fromJson(res);
    } catch (e) {
      if (_isTransportUnavailableError(e)) return null;
      return null;
    }
  }

  Future<void> _tryInitializeStandardMcp() async {
    const protocolVersions = <String>[
      '2025-03-26',
      '2024-11-05',
      '2024-10-07',
    ];
    for (final version in protocolVersions) {
      try {
        await callJsonRpc(
          method: 'initialize',
          params: <String, dynamic>{
            'protocolVersion': version,
            'capabilities': const <String, dynamic>{},
            'clientInfo': const <String, dynamic>{
              'name': 'mygril_flutter',
              'version': '1.0.0',
            },
          },
        );
        return;
      } catch (e) {
        if (_isTransportUnavailableError(e)) {
          // Network is unavailable; no need to try more protocol versions.
          return;
        }
        // Try next version.
      }
    }
    // Some gateways do not require initialize and allow tools/list directly.
  }

  bool _isTransportUnavailableError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('socketexception') ||
        message.contains('connection refused') ||
        message.contains('failed host lookup') ||
        message.contains('timed out') ||
        message.contains('timeout') ||
        message.contains('errno = 61') ||
        message.contains('errno = 111') ||
        message.contains('errno = 10061') ||
        message.contains('errno = 1225') ||
        // Gateway-level transient failures: retrying alternative MCP paths
        // on the same host usually just amplifies latency and log noise.
        message.contains('http 502') ||
        message.contains('http 503') ||
        message.contains('http 504') ||
        message.contains('bad gateway') ||
        message.contains('service unavailable') ||
        message.contains('gateway timeout') ||
        message.contains('upstream connect error') ||
        message.contains('upstream request timeout');
  }
}

String? _readString(dynamic value) {
  if (value == null) return null;
  if (value is String) return value;
  return value.toString();
}

bool _readBool(dynamic value, {required bool fallback}) {
  if (value == null) return fallback;
  if (value is bool) return value;
  final s = value.toString().trim().toLowerCase();
  if (s == 'true' || s == '1' || s == 'yes') return true;
  if (s == 'false' || s == '0' || s == 'no') return false;
  return fallback;
}

Map<String, dynamic>? _readMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    final out = <String, dynamic>{};
    value.forEach((k, v) {
      out[k.toString()] = v;
    });
    return out;
  }
  return null;
}

List<Map<String, dynamic>> _readMapList(dynamic value) {
  if (value is! List) return const <Map<String, dynamic>>[];
  final out = <Map<String, dynamic>>[];
  for (final item in value) {
    final map = _readMap(item);
    if (map != null) out.add(map);
  }
  return out;
}

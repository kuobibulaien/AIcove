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
      enabledTools: tools.map((e) => e.toString()).where((e) => e.isNotEmpty).toList(),
      delegate: McpDelegateConfigDto.fromJson(
        (json['delegate'] as Map<String, dynamic>?) ?? const <String, dynamic>{},
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
    return McpToolInfoDto(
      id: _readString(json['id']) ?? '',
      description: _readString(json['description']) ?? '',
      enabled: (json['enabled'] as bool?) ?? false,
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
    final configJson = (json['config'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    final toolsJson = (json['tools'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(McpToolInfoDto.fromJson)
        .toList();
    return McpConfigResponseDto(
      config: McpConfigDto.fromJson(configJson),
      tools: toolsJson,
    );
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
    double? _parseSpeed(dynamic value) {
      if (value == null || value == '' ) return null;
      final parsed = double.tryParse(value.toString());
      if (parsed == null || parsed <= 0) return null;
      return parsed;
    }

    return TtsToolConfigDto(
      apiKey: _readString(json['api_key']) ?? _readString(json['apiKey']) ?? '',
      promptAudioUrl: _readString(json['prompt_audio_url']) ?? _readString(json['promptAudioUrl']) ?? '',
      promptText: _readString(json['prompt_text']) ?? _readString(json['promptText']) ?? '',
      speed: _parseSpeed(json['speed']),
      requestUrl: _readString(json['request_url']) ?? _readString(json['requestUrl']) ?? '',
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

  const TtsPresetDto({required this.id, required this.name, required this.builtin, required this.config});

  factory TtsPresetDto.fromJson(Map<String, dynamic> json) {
    return TtsPresetDto(
      id: _readString(json['id']) ?? '',
      name: _readString(json['name']) ?? '未命名预设',
      builtin: json['builtin'] == true,
      config: TtsToolConfigDto.fromJson((json['config'] as Map<String, dynamic>? ?? const <String, dynamic>{})),
    );
  }
}

class TtsToolConfigResponseDto {
  final TtsToolConfigDto config;
  final TtsToolConfigDto defaults;
  final List<TtsPresetDto> presets;

  const TtsToolConfigResponseDto({required this.config, required this.defaults, required this.presets});

  factory TtsToolConfigResponseDto.fromJson(Map<String, dynamic> json) {
    final cfg = (json['config'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    final defs = (json['defaults'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
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
  final ApiClient _api;
  McpApi([ApiClient? api]) : _api = api ?? ApiClient();

  Future<McpConfigResponseDto> fetchConfig() async {
    final res = await _api.getJson('/mcp/config');
    return McpConfigResponseDto.fromJson(res);
  }

  Future<McpConfigResponseDto> updateConfig(McpConfigDto config) async {
    final res = await _api.putJson('/mcp/config', config.toJson());
    return McpConfigResponseDto.fromJson(res);
  }

  Future<McpToolTestResultDto> testTool(String toolId) async {
    final res = await _api.postJson('/mcp/tools/$toolId:test', {});
    return McpToolTestResultDto.fromJson(res);
  }

  Future<TtsToolConfigResponseDto> fetchTtsConfig() async {
    final res = await _api.getJson('/mcp/tts/config');
    return TtsToolConfigResponseDto.fromJson(res);
  }

  Future<TtsToolConfigResponseDto> updateTtsConfig(TtsToolConfigDto dto) async {
    final res = await _api.putJson('/mcp/tts/config', dto.toJson());
    return TtsToolConfigResponseDto.fromJson(res);
  }

  Future<TtsToolConfigResponseDto> createTtsPreset({required String name, required TtsToolConfigDto dto}) async {
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
}

String? _readString(dynamic value) {
  if (value == null) return null;
  if (value is String) return value;
  return value.toString();
}

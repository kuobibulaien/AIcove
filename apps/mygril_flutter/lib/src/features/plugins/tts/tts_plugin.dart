import 'package:flutter/material.dart';
import '../domain/plugin.dart';
import 'tts_config.dart';
import 'tts_parser.dart';
import 'tts_service.dart';

/// TTS 插件实现
/// 负责解析 <tts></tts> 标记，拆分文本，并生成 TTS 转换事件
class TtsPlugin extends Plugin {
  TtsConfig _config;
  late TtsService _service;

  TtsPlugin(this._config) {
    _service = TtsService(_config);
  }

  @override
  String get id => 'tts';

  @override
  String get name => '语音合成 (TTS)';

  @override
  String get description => '将标记文本自动转换为语音';

  @override
  IconData get icon => Icons.volume_up;

  @override
  bool get enabled => _config.enabled;

  @override
  Future<String?> getSystemPrompt({String? userMessage}) async {
    if (!enabled) {
      return null;
    }
    return _config.systemPromptTemplate;
  }

  @override
  Future<PluginProcessResult> processResponse(String text) async {
    if (!enabled) {
      return PluginProcessResult(
        processedText: text,
        events: [],
      );
    }

    // 1. 解析 TTS 标记
    final parseResult = TtsParser.parse(text);

    if (!parseResult.hasTtsContent) {
      return PluginProcessResult(
        processedText: text,
        events: [],
      );
    }

    // 2. 处理每个 TTS 段落
    final events = <PluginEvent>[];

    for (final segment in parseResult.segments) {
      // 拆分文本（如果超过最大字数）
      final chunks = TtsParser.splitText(
        segment.text,
        _config.maxCharsPerChunk,
      );

      // 为每个拆分块创建事件
      for (final chunk in chunks) {
        events.add(PluginEvent(
          pluginId: id,
          type: 'tts_convert',
          data: {
            'text': chunk,
            'originalText': segment.text,
            'config': {
              'requestUrl': _config.requestUrl,
              'promptAudioUrl': _config.promptAudioUrl,
              'promptText': _config.promptText,
              'speed': _config.speed,
            },
          },
        ));
      }
    }

    return PluginProcessResult(
      processedText: parseResult.cleanText,
      events: events,
    );
  }

  @override
  void updateConfig(Map<String, dynamic> config) {
    _config = TtsConfig.fromJson(config);
    _service = TtsService(_config);
  }

  @override
  Map<String, dynamic> getConfig() {
    return _config.toJson();
  }

  /// 获取当前配置对象
  TtsConfig get config => _config;

  /// 获取 TTS 服务实例
  TtsService get service => _service;

  /// 执行 TTS 转换
  /// 这是一个便捷方法，可以直接调用 TTS 服务
  Future<TtsConvertResult> convert(String text) async {
    return await _service.convert(text);
  }

  /// 批量转换
  Future<List<TtsConvertResult>> convertBatch(List<String> texts) async {
    return await _service.convertBatch(texts);
  }
}

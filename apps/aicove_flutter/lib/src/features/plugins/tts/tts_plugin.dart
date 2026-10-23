import 'package:flutter/material.dart';
import '../../content_tags/domain/content_tag_registry.dart';
import '../../content_tags/domain/content_tag_spec.dart';
import '../../agent_plugins/aicove_plugin.dart';
import '../domain/index.dart';
import '../../../core/app_logger.dart';
import '../prompts/plugin_prompt_resolution.dart';
import '../prompts/prompt_pack.dart';
import 'tts_agent_plugin.dart';
import 'tts_config.dart';
import 'tts_parser.dart';
import 'tts_service.dart';
import 'voice_request.dart';

/// TTS 插件实现
/// 负责解析 <tts></tts> 标记，拆分文本，并生成 TTS 转换事件
///
/// 重构说明：API Key 和 URL 现在从统一模型管理（ProviderAuth）获取，
/// 通过构造函数传入，不再存储在 TtsConfig 中。
class TtsPlugin extends BasePlugin {
  /// 语音插件拥有的语义标签与工具（ADR0044）。
  static const contentTags = StaticContentTagProvider(
    providerId: 'tts',
    tagSpecs: [
      ContentTagSpec(
        name: 'tts',
        ownerId: 'tts',
        display: ContentTagDisplay.tts,
      ),
    ],
    toolNames: {'speak'},
  );

  // ========== 元数据定义 ==========
  static const _metadata = PluginMetadata(
    id: 'tts',
    name: '语音合成 (TTS)',
    description: '将标记文本自动转换为语音',
    version: '1.0.0',
    author: 'AIcove Team',
    icon: Icons.volume_up,
    configSchema: {
      'enabled': ConfigField(
        type: ConfigFieldType.boolean,
        label: '启用插件',
        defaultValue: false,
      ),
      'selectedProviderId': ConfigField(
        type: ConfigFieldType.string,
        label: 'TTS 渠道',
        description: '选择已导入的 TTS 服务渠道',
      ),
      'promptAudioUrl': ConfigField(
        type: ConfigFieldType.string,
        label: '参考音频 URL',
        description: '用于克隆语音的参考音频地址',
      ),
      'promptText': ConfigField(
        type: ConfigFieldType.string,
        label: '参考文本',
        description: '参考音频对应的文本内容',
      ),
      'speed': ConfigField(
        type: ConfigFieldType.number,
        label: '语速',
        description: '语音播放速度，1.0 为正常速度',
        defaultValue: 1.0,
      ),
      'maxCharsPerChunk': ConfigField(
        type: ConfigFieldType.integer,
        label: '最大分片字数',
        description: '单次 TTS 请求的最大字符数',
        defaultValue: 200,
      ),
    },
  );

  // ========== 内部状态 ==========
  TtsConfig _ttsConfig;
  final String? _apiKey;
  final String _requestUrl;
  final String _requestFormat;
  final String? _selectedModel;
  final Map<String, dynamic>? _customConfig;
  late TtsService _service;

  /// 音色创建回调，用于保存自动创建的阿里云音色
  final Future<void> Function(VoicePreset updatedPreset)? _onVoiceCreated;
  final VoiceRequest? voiceRequest;

  /// 本次请求的提示词包；代码不在包外追加说明（ADR0092）。
  final ResolvedPromptPack? prompts;

  /// [prompts] 是本次音色预设解析出的提示词包（ADR0092）；为空时不注入说明。
  factory TtsPlugin.forRequest(
    VoiceRequest request, {
    ResolvedPromptPack? prompts,
  }) {
    final service = request.service;
    final config = service?.config ?? TtsConfig(enabled: false);
    return TtsPlugin(
      config,
      prompts: prompts,
      apiKey: service?.apiKey,
      requestUrl: service?.requestUrl ?? '',
      requestFormat: service?.requestFormat ?? 'openai_tts',
      selectedModel: service?.model,
      customConfig: service?.customConfig,
      voiceRequest: request,
    );
  }

  // ========== 构造函数 ==========
  TtsPlugin(
    this._ttsConfig, {
    String? apiKey,
    String requestUrl = '',
    String requestFormat = 'openai_tts',
    String? selectedModel,
    Map<String, dynamic>? customConfig,
    Future<void> Function(VoicePreset updatedPreset)? onVoiceCreated,
    this.voiceRequest,
    this.prompts,
  }) : _apiKey = apiKey,
       _requestUrl = requestUrl,
       _requestFormat = requestFormat,
       _selectedModel = selectedModel,
       _customConfig = customConfig,
       _onVoiceCreated = onVoiceCreated,
       super(metadata: _metadata) {
    _service = TtsService(
      config: _ttsConfig,
      apiKey: _apiKey,
      requestUrl: _requestUrl,
      requestFormat: _requestFormat,
      model: _selectedModel,
      customConfig: _customConfig ?? const <String, dynamic>{},
      onVoiceCreated: _onVoiceCreated,
    );
  }

  // ========== 重写 enabled getter ==========
  /// 插件启用状态：配置启用 且 渠道已配置 且 模型已选择
  @override
  bool get enabled => _ttsConfig.enabled;

  @override
  AicovePlugin get agentPlugin => ttsAgentPlugin(this);

  /// 是否已配置渠道（用于 UI 提示）
  bool get isConfigured => _requestUrl.isNotEmpty && _selectedModel != null;

  // ========== 生命周期方法 ==========

  @override
  Future<void> onInitialize() async {
    await super.onInitialize();
    AppLogger.info(
      'TTS',
      'TTS 插件初始化完成',
      metadata: {
        'pluginEnabled': _ttsConfig.enabled,
        'selectedProviderId': _ttsConfig.selectedProviderId,
        'configured': isConfigured,
        'requestFormat': _requestFormat,
        'requestUrl': _requestUrl,
      },
    );
  }

  @override
  Future<void> onEnable() async {
    await super.onEnable();
    AppLogger.info('TTS', 'TTS 插件已启用');
  }

  @override
  Future<void> onDisable() async {
    await super.onDisable();
    AppLogger.info('TTS', 'TTS 插件已禁用');
  }

  @override
  Future<void> onDestroy() async {
    // 清理服务资源
    await super.onDestroy();
    AppLogger.info('TTS', 'TTS 插件已销毁');
  }

  @override
  Future<void> onConfigChanged(Map<String, dynamic> newConfig) async {
    _ttsConfig = TtsConfig.fromJson(newConfig);
    _service = TtsService(
      config: _ttsConfig,
      apiKey: _apiKey,
      requestUrl: _requestUrl,
      requestFormat: _requestFormat,
      model: _selectedModel,
      customConfig: _customConfig ?? const <String, dynamic>{},
      onVoiceCreated: _onVoiceCreated,
    );
    AppLogger.info(
      'TTS',
      'TTS 插件配置已更新',
      metadata: {
        'pluginEnabled': _ttsConfig.enabled,
        'selectedProviderId': _ttsConfig.selectedProviderId,
        'model': _ttsConfig.model,
        'voice': _ttsConfig.voice,
        'useEmoText': _ttsConfig.useEmoText,
        'hasPromptAudioUrl':
            _ttsConfig.promptAudioUrl?.trim().isNotEmpty == true,
        'hasPromptText': _ttsConfig.promptText?.trim().isNotEmpty == true,
        'maxCharsPerChunk': _ttsConfig.maxCharsPerChunk,
      },
    );
  }

  // ========== 工具定义（原生 Tool Calling） ==========
  //
  // 暂时屏蔽工具路径，默认使用标签模式
  // 原因：工具调用需要等待 TTS 完成才能继续，导致响应延迟
  // 标签模式可以先返回文字，语音异步生成，用户体验更好
  //
  // 保留代码以备将来启用（如语音优先的交互场景）

  List<AITool> getTools() {
    // 暂时返回空列表，不注册 speak 工具
    return [];

    // === 以下为原工具定义，暂时屏蔽 ===
    // if (!enabled) return [];
    //
    // return [
    //   AITool(
    //     name: 'speak',
    //     description: '将文字转换为语音播放给用户听。当你想用声音表达情感、强调重点、或让对话更生动时使用此工具。',
    //     parameters: {
    //       'text': ToolParameter(
    //         type: 'string',
    //         description: '要朗读的文字内容，建议不超过50个字',
    //         required: true,
    //       ),
    //     },
    //     handler: (args) async {
    //       final text = args['text'] as String? ?? '';
    //       if (text.isEmpty) return '{"success": false, "error": "文本为空"}';
    //
    //       try {
    //         final result = await _service.convert(text);
    //         return '{"success": true, "audioUrl": "${result.audioUrl}", "text": "${_escapeJson(text)}"}';
    //       } catch (e) {
    //         AppLogger.warning('TTS', '工具调用 speak 失败', metadata: {'error': e.toString()});
    //         return '{"success": false, "error": "${_escapeJson(e.toString())}"}';
    //       }
    //     },
    //   ),
    // ];
  }

  // ========== 现有功能（保留） ==========

  /// 本次请求的 `<tts>` 标签说明，全部来自提示词包。
  String? buildTagSemanticsPrompt() {
    final pack = prompts;
    if (!enabled || pack == null) return null;
    final scope = _ttsConfig.voiceFrequency <= 0
        ? PromptScopes.ttsChatOff
        : PromptScopes.ttsChat;
    AppLogger.debug(
      'TTS',
      '注入 TTS 标签提示词',
      metadata: {
        'voiceFrequency': _ttsConfig.voiceFrequency,
        'pack': pack.pack.id,
        'automatic': pack.automatic,
      },
    );
    final prompt = pack.render(scope, voicePromptVariables(_ttsConfig));
    return prompt.isEmpty ? null : prompt;
  }

  /// Turns `<tts>` sections into speech events bound to [voiceRequest] and
  /// removes the tags.
  PluginProcessResult convertTtsTags(String text) {
    if (!enabled) {
      return PluginProcessResult(processedText: text, events: []);
    }

    // 1. 解析 TTS 标记
    final parseResult = TtsParser.parse(text);

    if (!parseResult.hasTtsContent) {
      AppLogger.info(
        'TTS',
        '本轮回复未包含 <tts> 标记，跳过语音生成',
        metadata: {'textLength': text.length},
      );
      return PluginProcessResult(processedText: text, events: []);
    }

    // 2. 处理每个 TTS 段落
    final events = <PluginEvent>[];

    for (final segment in parseResult.segments) {
      // 拆分文本（如果超过最大字数）
      final chunks = TtsParser.splitText(
        segment.text,
        _ttsConfig.maxCharsPerChunk,
      );

      // 为每个拆分块创建事件
      for (final chunk in chunks) {
        events.add(
          PluginEvent(
            pluginId: id,
            type: 'tts_convert',
            data: {
              'text': chunk,
              'originalText': segment.text,
              'config': {
                'promptAudioUrl': _ttsConfig.promptAudioUrl,
                'promptText': _ttsConfig.promptText,
                'speed': _ttsConfig.speed,
              },
            },
          ),
        );
      }
    }

    if (voiceRequest != null) {
      for (final event in events) {
        voiceRequest!.attach(event);
      }
    }
    AppLogger.info(
      'TTS',
      '解析到 <tts> 标记，已生成待转换事件',
      metadata: {
        'segments': parseResult.segments.length,
        'events': events.length,
        'maxCharsPerChunk': _ttsConfig.maxCharsPerChunk,
      },
    );
    return PluginProcessResult(
      processedText: parseResult.cleanText,
      events: events,
    );
  }

  @override
  void updateConfig(Map<String, dynamic> config) {
    _ttsConfig = TtsConfig.fromJson(config);
    _service = TtsService(
      config: _ttsConfig,
      apiKey: _apiKey,
      requestUrl: _requestUrl,
      requestFormat: _requestFormat,
      model: _selectedModel,
      customConfig: _customConfig ?? const <String, dynamic>{},
      onVoiceCreated: _onVoiceCreated,
    );
  }

  @override
  Map<String, dynamic> getConfig() {
    return _ttsConfig.toJson();
  }

  // ========== 工具方法（保留） ==========

  /// 获取当前配置对象
  TtsConfig get config => _ttsConfig;

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

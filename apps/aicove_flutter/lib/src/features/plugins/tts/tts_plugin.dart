import 'package:flutter/material.dart';
import '../../content_tags/domain/content_tag_registry.dart';
import '../../content_tags/domain/content_tag_spec.dart';
import '../domain/index.dart';
import '../../../core/app_logger.dart';
import '../../../core/prompts/prompt_builtin_defaults.g.dart';
import '../../../core/prompts/prompt_template_renderer.dart';
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

  static String get _minimaxGuide =>
      PromptBuiltinDefaults.requireTemplate('tts.minimax_guide');

  static const String _fishAudioGuide = r'''【Fish Audio (S2/S2.1) 语音控制】
你可以在 <tts> 标签内使用方括号 `[描述]` 进行词级自然语言语音控制，标签会影响其后面的内容：

1. 情绪标签（使用中括号）：
   - 根据上下文自由发挥，优先使用表演特征明显、强度足够的描述，不要过于普通或保守。
   - 例如：`[窃窃私语]`、`[笑着说]`、`[淫媚可怜]`、`[发情娇喘]`、`[崩溃哀求]` 等，不要局限于这些例子，应根据人物当时的状态自行生成最合适的标签。自然语言描述即可。
2. 台词内部加入人声、呼吸或局部语气标签（同样使用中括号）：
   - 例如：`[喘气]`、`[抽泣]`、`[呼吸急促]`、`[呻吟]`、`[哭腔]`、`[长停顿]`、`[短停顿]`、`[轻笑]`、`[叹气]` 等，可以自由使用其他符合上下文的表达。
   - 【推荐】鼓励大量叠用情绪标签以增强表演层次感，标签可以穿插在台词任意位置，逐段渲染出情绪的递进与爆发。
   - 普通示例：
     `啊[喘气][呻吟]主人[轻笑]你终于来了[高兴的笑声]`
     在每个词语的断句换气都可以使用标签，更多使用以及叠用标签可以增强气声。
   - nsfw示例：
     `[高潮的娇喘]小母狗，啊[被插入子宫]最喜欢主人了[颤音][高潮的尖叫]`
     请参照该示例的叠用密度与位置，根据人物状态自行生成最合适的标签组合。
3. 规则要求：
   - 标签必须放在受影响的词或短语前，且方括号标签后必须紧跟朗读台词。
   -  大多数场景都可以使用tts进行口语表达，不需要在意token。
   - 【严禁】<tts> 内部严禁包含任何颜文字（如 (^_^)、(*¯︶¯*) ）、Emoji 或装饰性特殊符号，包括爱心也不行，避免影响发音或引发杂音。''';

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

  factory TtsPlugin.forRequest(VoiceRequest request) {
    final service = request.service;
    return TtsPlugin(
      service?.config ?? TtsConfig(enabled: false),
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

  @override
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

  /// 获取系统提示词
  ///
  /// 始终返回标签模式的提示词（工具调用路径已暂时屏蔽）
  /// [supportsToolCalling] 参数暂时忽略，保留接口兼容性
  String? buildTagSemanticsPrompt() {
    if (!enabled) {
      return null;
    }

    // 频率为 0 时告知模型不要使用语音
    if (_ttsConfig.voiceFrequency <= 0) {
      return PromptBuiltinDefaults.requireTemplate(
        'tts.disabled_voice_frequency',
      );
    }

    // 检测是否为 MiniMax 渠道
    final isMinimaxProvider = _isMinimaxProvider();
    // 检测是否为 Fish Audio 渠道
    final isFishAudioProvider = _isFishAudioProvider();

    AppLogger.debug(
      'TTS',
      '注入 TTS 标签提示词',
      metadata: {
        'voiceFrequency': _ttsConfig.voiceFrequency,
        'isMinimaxProvider': isMinimaxProvider,
        'isFishAudioProvider': isFishAudioProvider,
      },
    );

    var prompt = _ttsConfig.systemPromptTemplate.trim();
    if (prompt.isEmpty ||
        prompt == PromptBuiltinDefaults.ttsSystemDefault.trim()) {
      prompt = PromptBuiltinDefaults.requireTemplate('tts.system.default');
    }

    prompt = PromptTemplateRenderer.renderTrimmed(prompt, <String, Object?>{
      'max_chars_per_chunk': _ttsConfig.maxCharsPerChunk,
      'voice_frequency': _ttsConfig.voiceFrequency,
      'minimax_guide': isMinimaxProvider ? _minimaxGuide : '',
      'fish_audio_guide': isFishAudioProvider ? _fishAudioGuide : '',
    }, collapseExtraBlankLines: true);

    if (isMinimaxProvider && !prompt.contains('MiniMax 语音增强')) {
      prompt = '$prompt\n\n$_minimaxGuide';
    } else if (isFishAudioProvider &&
        !prompt.contains('Fish Audio (S2/S2.1) 语音控制')) {
      prompt = '$prompt\n\n$_fishAudioGuide';
    }

    return prompt.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  @override
  Future<String?> getSystemPrompt({
    String? userMessage,
    bool supportsToolCalling = false,
  }) async {
    return buildTagSemanticsPrompt();
  }

  /// 判断当前是否使用 MiniMax 渠道
  bool _isMinimaxProvider() {
    // 方式1：通过 requestFormat 判断
    if (_requestFormat.toLowerCase().contains('minimax')) {
      return true;
    }
    // 方式2：通过 URL 判断
    if (_requestUrl.toLowerCase().contains('minimax')) {
      return true;
    }
    return false;
  }

  /// 判断当前是否使用 Fish Audio 渠道
  bool _isFishAudioProvider() {
    final format = _requestFormat.toLowerCase();
    if (format.contains('fish_audio') || format.contains('fishaudio')) {
      return true;
    }
    final url = _requestUrl.toLowerCase();
    if (url.contains('fish.audio')) {
      return true;
    }
    final model = (_selectedModel ?? _ttsConfig.model ?? '').toLowerCase();
    if (model.contains('s2.1') || model.contains('s2-pro')) {
      return true;
    }
    return false;
  }

  @override
  Future<PluginProcessResult> processResponse(String text) async {
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

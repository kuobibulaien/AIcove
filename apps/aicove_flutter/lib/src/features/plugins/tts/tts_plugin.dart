import 'package:flutter/material.dart';
import '../domain/index.dart';
import '../../../core/app_logger.dart';
import 'tts_config.dart';
import 'tts_parser.dart';
import 'tts_service.dart';

/// TTS 插件实现
/// 负责解析 <tts></tts> 标记，拆分文本，并生成 TTS 转换事件
///
/// 重构说明：API Key 和 URL 现在从统一模型管理（ProviderAuth）获取，
/// 通过构造函数传入，不再存储在 TtsConfig 中。
class TtsPlugin extends BasePlugin {
  // ========== 元数据定义 ==========
  static final _metadata = PluginMetadata(
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
  String? _apiKey;
  String _requestUrl;
  String _requestFormat;
  String? _selectedModel;
  late TtsService _service;

  /// 音色创建回调，用于保存自动创建的阿里云音色
  Future<void> Function(VoicePreset updatedPreset)? _onVoiceCreated;

  // ========== 构造函数 ==========
  TtsPlugin(
    this._ttsConfig, {
    String? apiKey,
    String requestUrl = '',
    String requestFormat = 'openai_tts',
    String? selectedModel,
    Future<void> Function(VoicePreset updatedPreset)? onVoiceCreated,
  })  : _apiKey = apiKey,
        _requestUrl = requestUrl,
        _requestFormat = requestFormat,
        _selectedModel = selectedModel,
        _onVoiceCreated = onVoiceCreated,
        super(metadata: _metadata) {
    _service = TtsService(
      config: _ttsConfig,
      apiKey: _apiKey,
      requestUrl: _requestUrl,
      requestFormat: _requestFormat,
      model: _selectedModel,
      onVoiceCreated: _onVoiceCreated,
    );
  }

  // ========== 重写 enabled getter ==========
  /// 插件启用状态：配置启用 且 渠道已配置 且 模型已选择
  @override
  bool get enabled => _ttsConfig.enabled && _requestUrl.isNotEmpty && _selectedModel != null;

  /// 是否已配置渠道（用于 UI 提示）
  bool get isConfigured => _requestUrl.isNotEmpty && _selectedModel != null;

  // ========== 生命周期方法 ==========
  
  @override
  Future<void> onInitialize() async {
    await super.onInitialize();
    AppLogger.info('TTS', 'TTS 插件初始化完成', metadata: {
      'pluginEnabled': _ttsConfig.enabled,
      'selectedProviderId': _ttsConfig.selectedProviderId,
      'configured': isConfigured,
      'requestFormat': _requestFormat,
      'requestUrl': _requestUrl,
    });
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
      onVoiceCreated: _onVoiceCreated,
    );
    AppLogger.info('TTS', 'TTS 插件配置已更新', metadata: {
      'pluginEnabled': _ttsConfig.enabled,
      'selectedProviderId': _ttsConfig.selectedProviderId,
      'model': _ttsConfig.model,
      'voice': _ttsConfig.voice,
      'useEmoText': _ttsConfig.useEmoText,
      'hasPromptAudioUrl': _ttsConfig.promptAudioUrl?.trim().isNotEmpty == true,
      'hasPromptText': _ttsConfig.promptText?.trim().isNotEmpty == true,
      'maxCharsPerChunk': _ttsConfig.maxCharsPerChunk,
    });
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
  @override
  Future<String?> getSystemPrompt({String? userMessage, bool supportsToolCalling = false}) async {
    if (!enabled) {
      return null;
    }

    // 根据语音频率生成使用指导
    final frequencyGuide = _getFrequencyGuide(_ttsConfig.voiceFrequency);

    // 检测是否为 MiniMax 渠道
    final isMinimaxProvider = _isMinimaxProvider();

    // 始终使用标签模式（工具调用路径已屏蔽）
    AppLogger.debug('TTS', '注入 TTS 标签提示词', metadata: {
      'maxCharsPerChunk': _ttsConfig.maxCharsPerChunk,
      'voiceFrequency': _ttsConfig.voiceFrequency,
      'isMinimaxProvider': isMinimaxProvider,
    });

    // MiniMax 特有的语气词和停顿说明
    final minimaxGuide = isMinimaxProvider ? '''

【MiniMax 语音增强】
你可以在 <tts> 标签内使用以下增强功能：

1. 语气词标签（让语音更自然生动）：
   - (laughs) 笑声、(chuckle) 轻笑、(sighs) 叹气
   - (crying) 抽泣、(gasps) 倒吸气、(emm) 嗯
   - (breath) 换气、(pant) 喘气、(inhale) 吸气、(exhale) 呼气
   - (coughs) 咳嗽、(clear-throat) 清嗓子、(sniffs) 吸鼻子
   - (humming) 哼唱、(whistles) 口哨、(applause) 鼓掌
   示例：<tts>你好呀(laughs)，今天心情怎么样？</tts>

2. 停顿控制：
   - 使用 <#秒数#> 控制停顿，如 <#0.5#> 表示停顿 0.5 秒
   - 范围：0.01~99.99 秒
   示例：<tts>让我想想<#1.5#>嗯，我觉得可以！</tts>
''' : '';

    return '''
你可以使用 <tts>文本</tts> 标记来生成语音。

$frequencyGuide

使用规则：
1. 将需要转换为语音的文本用 <tts></tts> 标记包裹
2. 每个 <tts></tts> 标记内的文本不要超过 ${_ttsConfig.maxCharsPerChunk} 个字
3. 一轮对话中可以使用多个 <tts></tts> 标记

示例：
<tts>你好，很高兴见到你！</tts>
$minimaxGuide''';
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

  /// 根据语音频率生成使用指导文本
  String _getFrequencyGuide(int frequency) {
    if (frequency <= 0) {
      return '【重要】用户不希望你使用语音功能，请只用文字回复。';
    } else if (frequency <= 20) {
      return '语音使用频率：极少。只在非常重要或情感强烈的时刻才使用语音，绝大多数情况用文字回复。';
    } else if (frequency <= 40) {
      return '语音使用频率：偶尔。在重点内容、情感表达、或需要强调时使用语音，日常交流用文字。';
    } else if (frequency <= 60) {
      return '语音使用频率：适中。可以较自由地使用语音，但仍保持文字为主，语音点缀。';
    } else if (frequency <= 80) {
      return '语音使用频率：较多。积极使用语音来增强表达效果，让对话更生动有趣。';
    } else {
      return '语音使用频率：频繁。尽可能多地使用语音，让对话充满活力和情感。';
    }
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
      AppLogger.info('TTS', '本轮回复未包含 <tts> 标记，跳过语音生成', metadata: {
        'textLength': text.length,
      });
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
        _ttsConfig.maxCharsPerChunk,
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
              'promptAudioUrl': _ttsConfig.promptAudioUrl,
              'promptText': _ttsConfig.promptText,
              'speed': _ttsConfig.speed,
            },
          },
        ));
      }
    }

    AppLogger.info('TTS', '解析到 <tts> 标记，已生成待转换事件', metadata: {
      'segments': parseResult.segments.length,
      'events': events.length,
      'maxCharsPerChunk': _ttsConfig.maxCharsPerChunk,
    });
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

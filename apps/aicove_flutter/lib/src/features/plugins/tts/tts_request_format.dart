/// 语音渠道请求格式注册表
///
/// 语音渠道的唯一协议入口：添加页、详情页、存储规整与合成路由都从这里取格式，
/// 合成只认渠道 `customConfig.requestFormat`，不再按地址或模型名猜厂商。
library;

import 'dart:convert';

class TtsRequestFormat {
  const TtsRequestFormat._({
    required this.value,
    required this.label,
    required this.defaultBaseUrl,
    this.providerId,
    this.defaultModels = const <String>[],
  });

  /// 写入 customConfig.requestFormat 的值。
  final String value;
  final String label;
  final String defaultBaseUrl;

  /// 导入时的渠道 id 前缀；为空时使用 [value]。
  final String? providerId;

  /// 拉取不到模型列表时使用的默认模型。
  final List<String> defaultModels;

  static const openai = TtsRequestFormat._(
    value: 'openai_tts',
    label: 'OpenAI',
    providerId: 'openai',
    defaultBaseUrl: 'https://api.openai.com/v1',
    defaultModels: <String>['gpt-4o-mini-tts', 'tts-1', 'tts-1-hd'],
  );
  static const minimax = TtsRequestFormat._(
    value: 'minimax',
    label: 'MiniMax',
    defaultBaseUrl: 'https://api.minimaxi.com/v1',
    defaultModels: <String>['speech-2.8-hd', 'speech-2.8-turbo'],
  );

  /// 阿里云百炼：CosyVoice 与 Qwen-TTS 端点不同，合成时按模型名分流。
  static const aliyun = TtsRequestFormat._(
    value: 'aliyun',
    label: '阿里云',
    defaultBaseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    defaultModels: <String>[
      'cosyvoice-v3-plus',
      'qwen3-tts-vc-realtime-2026-01-15',
    ],
  );
  static const fishAudio = TtsRequestFormat._(
    value: 'fish_audio',
    label: 'Fish Audio',
    defaultBaseUrl: 'https://api.fish.audio/v1',
    // 官方没有列模型接口，取自 /v1/tts 文档 model 请求头的枚举值。
    defaultModels: <String>[
      's2.1-pro-free',
      's2.1-pro',
      's2-pro',
      's1',
      'drama-3',
    ],
  );

  /// 自定义 REST：路径、请求头、请求体由 customConfig.tts_template 描述。
  static const customRest = TtsRequestFormat._(
    value: 'custom_rest',
    label: '自定义 REST',
    defaultBaseUrl: '',
  );

  static const all = <TtsRequestFormat>[
    openai,
    minimax,
    aliyun,
    fishAudio,
    customRest,
  ];

  /// 旧数据里出现过的别名。硅基流动已下线，其 /audio/speech 兼容 OpenAI。
  static const _aliases = <String, TtsRequestFormat>{
    'openai_tts': openai,
    'siliconflow_indextts': openai,
    'minimax': minimax,
    'minimax_tts': minimax,
    'aliyun': aliyun,
    'aliyun_cosyvoice': aliyun,
    'aliyun_qwen_tts': aliyun,
    'fish_audio': fishAudio,
    'fishaudio': fishAudio,
    'custom_rest': customRest,
    'configurable_rest': customRest,
    'template': customRest,
  };

  /// 不是语音格式（含对话格式 `openai`）时返回 null。
  static TtsRequestFormat? fromRaw(String? raw) {
    final normalized = raw?.trim().toLowerCase() ?? '';
    return _aliases[normalized];
  }

  static bool isTtsFormat(String? raw) => fromRaw(raw) != null;

  /// 这类格式的模型名推断不出语音类型（如 Fish 的 s2.1-pro），渠道内模型一律按语音处理。
  bool get forcesTtsModels => this == fishAudio || this == customRest;

  /// 自定义 REST 模板在 customConfig 中的键。
  static const customRestTemplateKey = 'tts_template';

  /// 解析并校验自定义 REST 模板 JSON；不合法时抛 [FormatException]。
  static Map<String, dynamic> parseCustomRestTemplate(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const FormatException('不是有效的 JSON');
    }
    if (decoded is! Map) throw const FormatException('模板必须是 JSON 对象');
    final template = Map<String, dynamic>.from(decoded);
    final path = template['path'];
    if (path != null && path is! String) {
      throw const FormatException('path 必须是字符串');
    }
    final headers = template['headers'];
    if (headers != null && headers is! Map) {
      throw const FormatException('headers 必须是 JSON 对象');
    }
    if (template['body'] is! Map) {
      throw const FormatException('缺少 body 对象');
    }
    return template;
  }

  /// 自定义 REST 的初始模板，与 OpenAI /audio/speech 同形，便于照着改。
  static const defaultCustomRestTemplate = <String, dynamic>{
    'path': '/audio/speech',
    'headers': <String, dynamic>{},
    'body': <String, dynamic>{
      'model': '{model}',
      'input': '{text}',
      'voice': '{voice}',
      'response_format': 'mp3',
    },
  };

  /// 把旧数据规整成显式格式。
  ///
  /// 已是语音格式的旧别名改写为规范值（显式的阿里云子格式保留，合成时更精确）；
  /// 未写格式或写的是 `openai_tts` 的语音渠道，按地址补一次厂商格式。
  /// 非语音渠道返回 null，表示不改。
  static String? normalizeStored({
    required String? rawFormat,
    required String apiBaseUrl,
    required bool isTtsProvider,
  }) {
    final raw = rawFormat?.trim().toLowerCase() ?? '';
    if (raw == 'aliyun_cosyvoice' || raw == 'aliyun_qwen_tts') return raw;
    final known = fromRaw(raw);
    if (known != null && known != openai) return known.value;
    if (raw.isNotEmpty && known == null) return null;
    if (!isTtsProvider && known == null) return null;

    final host = Uri.tryParse(apiBaseUrl.trim())?.host.toLowerCase() ?? '';
    if (host.contains('dashscope')) return aliyun.value;
    if (host.contains('fish.audio')) return fishAudio.value;
    if (host.contains('minimax')) return minimax.value;
    return openai.value;
  }
}

/// 语音识别渠道格式注册表
///
/// 语音识别的唯一协议入口：添加页、详情页、存储规整与识别器装配都从这里取格式。
/// 格式存在渠道 `customConfig.asrRequestFormat`，与对话／语音合成的 `requestFormat` 互不干扰，
/// 同一个渠道（如阿里云）可以同时有合成模型和识别模型。识别只认这个字段，不按地址或模型名猜。
library;

/// 除 API Key 外还要填的凭证，存在 `customConfig[key]`。
class AsrCredentialField {
  const AsrCredentialField({
    required this.key,
    required this.label,
    this.hint,
    this.optional = false,
  });

  final String key;
  final String label;
  final String? hint;
  final bool optional;
}

class AsrRequestFormat {
  const AsrRequestFormat._({
    required this.value,
    required this.label,
    required this.defaultEndpoint,
    required this.providerId,
    required this.defaultModels,
    this.apiKeyLabel = 'API Key',
    this.credentialFields = const <AsrCredentialField>[],
  });

  /// 写入 customConfig.asrRequestFormat 的值。
  final String value;
  final String label;

  /// 默认 WebSocket 地址；渠道地址填的是 ws(s):// 时以渠道地址为准。
  final String defaultEndpoint;

  /// 导入时的渠道 id 前缀。
  final String providerId;

  /// 拉取不到模型列表时使用的默认模型（各家都没有列模型的接口）。
  final List<String> defaultModels;

  /// API Key 输入框在这家叫什么（腾讯是 SecretKey）。
  final String apiKeyLabel;
  final List<AsrCredentialField> credentialFields;

  /// 阿里云百炼：Fun-ASR／Paraformer 走 run-task 协议，Qwen3-ASR 实时版走 realtime 协议，
  /// 按模型名分流（[isAliyunQwenRealtimeModel]）。
  static const aliyun = AsrRequestFormat._(
    value: 'aliyun_asr',
    label: '阿里云百炼',
    defaultEndpoint: 'wss://dashscope.aliyuncs.com/api-ws/v1/inference',
    providerId: 'aliyun',
    defaultModels: <String>[
      'fun-asr-realtime',
      'paraformer-realtime-v2',
      'qwen3-asr-flash-realtime',
    ],
  );

  /// 火山引擎豆包流式语音识别（双向流式优化版），模型名即 X-Api-Resource-Id。
  static const volcengine = AsrRequestFormat._(
    value: 'volcengine_asr',
    label: '火山引擎（豆包）',
    defaultEndpoint:
        'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async',
    providerId: 'volcengine_asr',
    defaultModels: <String>[
      'volc.seedasr.sauc.duration',
      'volc.seedasr.sauc.concurrent',
      'volc.bigasr.sauc.duration',
    ],
    credentialFields: <AsrCredentialField>[
      AsrCredentialField(
        key: 'asr_app_id',
        label: 'App ID',
        hint: '旧版控制台才需要；填了 App ID，API Key 填 Access Token',
        optional: true,
      ),
    ],
  );

  /// 腾讯云实时语音识别，模型名即 engine_model_type。
  static const tencent = AsrRequestFormat._(
    value: 'tencent_asr',
    label: '腾讯云',
    defaultEndpoint: 'wss://asr.cloud.tencent.com/asr/v2',
    providerId: 'tencent_asr',
    defaultModels: <String>['16k_zh', '16k_zh_en', 'Hy-ASR-3.0-preview'],
    apiKeyLabel: 'SecretKey',
    credentialFields: <AsrCredentialField>[
      AsrCredentialField(key: 'asr_app_id', label: 'AppID'),
      AsrCredentialField(key: 'asr_secret_id', label: 'SecretId'),
    ],
  );

  /// 讯飞实时语音转写（标准版）。
  static const xfyun = AsrRequestFormat._(
    value: 'xfyun_rtasr',
    label: '讯飞',
    defaultEndpoint: 'wss://rtasr.xfyun.cn/v1/ws',
    providerId: 'xfyun_asr',
    defaultModels: <String>['rtasr'],
    apiKeyLabel: 'APIKey',
    credentialFields: <AsrCredentialField>[
      AsrCredentialField(key: 'asr_app_id', label: 'APPID'),
    ],
  );

  /// OpenAI Realtime 转写会话（服务端 VAD）。
  static const openai = AsrRequestFormat._(
    value: 'openai_realtime_asr',
    label: 'OpenAI Realtime',
    defaultEndpoint: 'wss://api.openai.com/v1/realtime',
    providerId: 'openai',
    defaultModels: <String>['gpt-4o-transcribe', 'gpt-4o-mini-transcribe'],
  );

  static const deepgram = AsrRequestFormat._(
    value: 'deepgram',
    label: 'Deepgram',
    defaultEndpoint: 'wss://api.deepgram.com/v1/listen',
    providerId: 'deepgram',
    defaultModels: <String>['nova-3', 'nova-2'],
    credentialFields: <AsrCredentialField>[
      AsrCredentialField(
        key: 'asr_language',
        label: '语言',
        hint: '默认 zh-CN',
        optional: true,
      ),
    ],
  );

  static const elevenlabs = AsrRequestFormat._(
    value: 'elevenlabs_asr',
    label: 'ElevenLabs',
    defaultEndpoint: 'wss://api.elevenlabs.io/v1/speech-to-text/realtime',
    providerId: 'elevenlabs',
    defaultModels: <String>['scribe_v2_realtime'],
  );

  static const all = <AsrRequestFormat>[
    aliyun,
    volcengine,
    tencent,
    xfyun,
    openai,
    deepgram,
    elevenlabs,
  ];

  /// 渠道配置里存识别格式的键。
  static const configKey = 'asrRequestFormat';

  static AsrRequestFormat? fromRaw(String? raw) {
    final normalized = raw?.trim().toLowerCase() ?? '';
    for (final format in all) {
      if (format.value == normalized) return format;
    }
    return null;
  }

  static AsrRequestFormat? ofConfig(Map<String, dynamic> customConfig) =>
      fromRaw(customConfig[configKey]?.toString());

  /// 阿里云里走 realtime 协议（OpenAI 风格事件）的 Qwen3-ASR 实时模型。
  static bool isAliyunQwenRealtimeModel(String model) =>
      model.trim().toLowerCase().startsWith('qwen3-asr');

  /// 渠道没写识别格式时补一次：只对有识别模型的渠道，按地址认厂商，认不出按 OpenAI。
  /// 已写了合法格式就不改；返回 null 表示不写。
  static String? normalizeStored({
    required String? rawFormat,
    required String apiBaseUrl,
    required bool hasSpeechRecognitionModels,
  }) {
    final known = fromRaw(rawFormat);
    if (known != null) return known.value;
    if (!hasSpeechRecognitionModels) return null;
    final host = Uri.tryParse(apiBaseUrl.trim())?.host.toLowerCase() ?? '';
    if (host.contains('dashscope')) return aliyun.value;
    if (host.contains('bytedance') || host.contains('volces')) {
      return volcengine.value;
    }
    if (host.contains('tencent')) return tencent.value;
    if (host.contains('xfyun') || host.contains('iflytek')) return xfyun.value;
    if (host.contains('deepgram')) return deepgram.value;
    if (host.contains('elevenlabs')) return elevenlabs.value;
    return openai.value;
  }

  /// 识别器连接地址：渠道地址是 ws(s):// 就照用；是 http(s):// 时换成同主机的识别地址
  /// （百炼国际站、OpenAI 兼容代理），其余用默认地址。
  Uri endpointFor(String apiBaseUrl, {String? model}) {
    final base = Uri.tryParse(apiBaseUrl.trim());
    if (base != null && (base.scheme == 'ws' || base.scheme == 'wss')) {
      return base;
    }
    final fallback = Uri.parse(defaultEndpoint);
    if (base == null || base.host.isEmpty) return fallback;
    final secure = base.scheme != 'http';
    if (this == aliyun && base.host.contains('dashscope')) {
      return fallback.replace(scheme: secure ? 'wss' : 'ws', host: base.host);
    }
    if (this == openai) {
      final path = base.path.endsWith('/')
          ? base.path.substring(0, base.path.length - 1)
          : base.path;
      return Uri(
        scheme: secure ? 'wss' : 'ws',
        host: base.host,
        port: base.hasPort ? base.port : null,
        path: '$path/realtime',
      );
    }
    return fallback;
  }
}

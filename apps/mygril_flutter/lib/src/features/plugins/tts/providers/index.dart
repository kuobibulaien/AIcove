/// TTS Provider 统一导出
///
/// 提供 TTS 音色管理的统一抽象层
///
/// 使用示例:
/// ```dart
/// import 'package:mygril_flutter/src/features/plugins/tts/providers/index.dart';
///
/// // 获取指定渠道的 Provider
/// final provider = TtsProviderFactory.getProvider('siliconflow');
///
/// // 获取音色列表
/// final voices = await provider?.listVoices(apiKey: 'xxx');
///
/// // 创建音色
/// final result = await provider?.createVoice(
///   apiKey: 'xxx',
///   request: VoiceCreateRequest(
///     name: '我的音色',
///     audioBytes: audioData,
///     fileName: 'voice.mp3',
///     promptText: '这是参考文本',
///   ),
/// );
/// ```
library;

export 'tts_voice_provider.dart';
export 'tts_provider_factory.dart';
export 'siliconflow_voice_provider.dart';
export 'aliyun_voice_provider.dart';
export 'minimax_voice_provider.dart';

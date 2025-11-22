/// 统一导出所有插件相关类和功能
library plugins;

// 插件核心
export 'domain/plugin.dart';
export 'plugin_manager.dart';
export 'plugin_providers.dart';

// TTS 插件
export 'tts/tts_config.dart';
export 'tts/tts_parser.dart';
export 'tts/tts_service.dart';
export 'tts/tts_plugin.dart';
export 'tts/tts_player_manager.dart';

// Trigger 插件
export 'trigger/trigger_config.dart';
export 'trigger/trigger_service.dart';
export 'trigger/trigger_plugin.dart';

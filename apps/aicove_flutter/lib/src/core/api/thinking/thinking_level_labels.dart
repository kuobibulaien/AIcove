import 'thinking_level.dart';

/// 档位的中文标题。原生档位保留英文名便于与上游文档对照。
String thinkingLevelTitle(ThinkingLevel level, {required bool isNative}) {
  return switch (level) {
    ThinkingLevel.auto => '跟随上游',
    ThinkingLevel.off => '关',
    ThinkingLevel.minimal => isNative ? 'minimal' : '极低',
    ThinkingLevel.low => isNative ? 'low' : '低',
    ThinkingLevel.medium => isNative ? 'medium' : '中',
    ThinkingLevel.high => isNative ? 'high' : '高',
    ThinkingLevel.xhigh => 'xhigh',
    ThinkingLevel.max => 'max',
  };
}

/// 一句新手说明。
String thinkingLevelHint(ThinkingLevel level) {
  return switch (level) {
    ThinkingLevel.auto => '不发送思考参数，由服务商自己决定',
    ThinkingLevel.off => '不思考，回复最快最省',
    ThinkingLevel.minimal => '几乎不思考，适合简单问答',
    ThinkingLevel.low => '轻度思考，日常对话足够',
    ThinkingLevel.medium => '中等思考，兼顾速度和质量',
    ThinkingLevel.high => '深度思考，复杂问题更准但更慢',
    ThinkingLevel.xhigh => '极深思考，最慢最贵',
    ThinkingLevel.max => '不限思考量，只在极难任务用',
  };
}

/// 档位来源标签。
enum ThinkingLevelSource { session, model, preset, softwareDefault }

String thinkingLevelSourceLabel(ThinkingLevelSource source) {
  return switch (source) {
    ThinkingLevelSource.session => '本会话设置',
    ThinkingLevelSource.model => '模型默认',
    ThinkingLevelSource.preset => '预设',
    ThinkingLevelSource.softwareDefault => '软件默认',
  };
}

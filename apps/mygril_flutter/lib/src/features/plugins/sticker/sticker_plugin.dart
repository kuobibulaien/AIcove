import 'package:flutter/material.dart';

import '../domain/index.dart';
import '../../stickers/sticker_registry.dart';
import 'sticker_config.dart';

/// 表情包插件 - 解析 AI 回复中的 [标签] 并转换为表情包
/// 
/// 工作流程：
/// 1. AI 回复中使用 [标签] 标记表情包，如 "晚安~ [晚安]"
/// 2. 插件解析 [xxx] 标签，匹配到对应表情包
/// 3. 生成 sticker_convert 事件，携带表情包信息
/// 4. 消息构建时将事件转换为 EmojiBlock
class StickerPlugin extends BasePlugin {
  // ========== 元数据定义 ==========
  static final _metadata = PluginMetadata(
    id: 'sticker',
    name: '表情包',
    description: '自动将 [标签] 转换为表情包',
    version: '1.0.0',
    author: 'AIcove Team',
    icon: Icons.emoji_emotions,
    configSchema: {
      'enabled': ConfigField(
        type: ConfigFieldType.boolean,
        label: '启用插件',
        defaultValue: true,
      ),
    },
  );

  // ========== 内部状态 ==========
  StickerConfig _stickerConfig;
  
  // ========== 构造函数 ==========
  StickerPlugin(this._stickerConfig) : super(metadata: _metadata);

  // ========== 重写 enabled getter ==========
  @override
  bool get enabled => _stickerConfig.enabled;

  // ========== 生命周期方法 ==========

  @override
  Future<void> onInitialize() async {
    await super.onInitialize();
    debugPrint('[StickerPlugin] 初始化完成');
  }

  // ========== 现有功能（保留） ==========
  
  @override
  Future<String?> getSystemPrompt({String? userMessage, bool supportsToolCalling = false}) async {
    if (!enabled) return null;
    
    // 获取所有可用标签
    final registry = StickerRegistry.instance;
    final tags = registry.allTags.toList()..sort();
    
    if (tags.isEmpty) return null;
    
    return '''
你可以在回复中使用表情包来增加趣味性。使用方法：在合适的地方用 [标签] 标记。

可用的表情包标签：${tags.join('、')}

示例：
- "晚安呀~ [晚安]"
- "太感谢你了！[谢谢]"
- "好累啊 [摸鱼]"

注意：
- 不要每句话都用表情包，适度使用
- 表情包放在句尾效果更自然
- 同义词会自动匹配（如"睡觉"会匹配到"晚安"组的表情包）
''';
  }
  
  @override
  Future<PluginProcessResult> processResponse(String text) async {
    if (!enabled || text.isEmpty) {
      return PluginProcessResult(processedText: text, events: []);
    }
    
    final events = <PluginEvent>[];
    String processedText = text;
    
    // 匹配 [xxx] 格式的标签
    final regex = RegExp(r'\[([^\[\]]+)\]');
    final matches = regex.allMatches(text).toList();
    
    for (final match in matches) {
      final tag = match.group(1)?.trim() ?? '';
      if (tag.isEmpty) continue;
      
      // 查找匹配的表情包
      final registry = StickerRegistry.instance;
      final sticker = registry.getByTag(tag);
      
      if (sticker != null) {
        // 生成表情包转换事件
        events.add(PluginEvent(
          pluginId: id,
          type: 'sticker_convert',
          data: {
            'tag': tag,
            'stickerId': sticker.id,
            'assetPath': sticker.assetPath,
            'description': sticker.description,
          },
        ));
        
        // 从文本中移除标签
        processedText = processedText.replaceFirst(match.group(0)!, '');
      }
    }
    
    // 清理多余空格
    processedText = processedText.replaceAll(RegExp(r'\s+'), ' ').trim();
    
    return PluginProcessResult(
      processedText: processedText,
      events: events,
    );
  }
  
  @override
  void updateConfig(Map<String, dynamic> config) {
    _stickerConfig = StickerConfig.fromJson(config);
  }
  
  @override
  Map<String, dynamic> getConfig() => _stickerConfig.toJson();
  
  /// 更新配置（类型安全版本）
  void updateStickerConfig(StickerConfig config) {
    _stickerConfig = config;
  }
}

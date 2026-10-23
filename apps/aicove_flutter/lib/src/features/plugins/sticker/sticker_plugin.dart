import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/index.dart';
import '../../agent_plugins/aicove_plugin.dart';
import '../../../core/prompts/prompt_builtin_defaults.g.dart';
import '../../../core/prompts/prompt_template_renderer.dart';
import '../../content_tags/domain/content_tag_scanner.dart';
import '../../stickers/sticker_library.dart';
import '../../stickers/sticker_pack_grants.dart';
import '../../stickers/sticker_registry.dart';
import '../../stickers/sticker_tag.dart';
import '../plugin_content_tags.dart';
import 'sticker_agent_plugin.dart';
import 'sticker_config.dart';

/// 表情包插件 - 解析 AI 回复中的 `<sticker tag="标签"/>` 并转换为表情包
///
/// 工作流程：
/// 1. AI 回复中写 `<sticker tag="晚安"/>` 标记表情包（自闭合，不用方括号）
/// 2. 插件用统一扫描器找到表情标签，匹配到对应表情包并移除标签
/// 3. 生成 sticker_convert 事件，携带表情包信息
/// 4. 消息构建时将事件转换为 EmojiBlock
class StickerPlugin extends BasePlugin {
  // ========== 元数据定义 ==========
  static const _metadata = PluginMetadata(
    id: 'sticker',
    name: '表情包',
    description: '自动将 <sticker tag="标签"/> 转换为表情包',
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

  StickerConfig get config => _stickerConfig;

  @override
  AicovePlugin get agentPlugin => stickerAgentPlugin(this);

  // ========== 生命周期方法 ==========

  @override
  Future<void> onInitialize() async {
    await super.onInitialize();
    debugPrint('[StickerPlugin] 初始化完成');
  }

  // ========== 现有功能（保留） ==========

  /// Tag list prompt; null when off or no stickers are installed.
  /// [rolePluginIds] is the role's plugin list, which carries its pack grants
  /// (null = every enabled pack).
  Future<String?> buildSystemPrompt({Iterable<String>? rolePluginIds}) async {
    if (!enabled) return null;

    await StickerLibrary.ensureLoaded();
    final registry = StickerRegistry.instance;
    final tags = registry
        .tagsIn(StickerPackGrants.effective(rolePluginIds, registry.packIds))
        .toList()
      ..sort();

    if (tags.isEmpty) return null;

    final template = _stickerConfig.systemPromptTemplate.trim() ==
            PromptBuiltinDefaults.stickerSystemDefault.trim()
        ? PromptBuiltinDefaults.requireTemplate(
            'sticker.system.default',
          )
        : _stickerConfig.systemPromptTemplate;

    return PromptTemplateRenderer.renderTrimmed(
      template,
      <String, Object?>{
        'tags': tags.join('、'),
      },
    );
  }

  /// 把 `<sticker tag="…"/>` 换成表情事件，并从正文里移除标签。
  ///
  /// 只有顶层标签产生事件；语音、图片等标签里面的表情标签直接删掉、不产生事件，
  /// 与消息切段（ChatMessageProcessor）的口径一致，保证事件与段一一对应。
  /// 只从角色可用的套组里挑图（[rolePluginIds] 同 [buildSystemPrompt]）。
  Future<PluginProcessResult> convertStickerTags(
    String text, {
    Iterable<String>? rolePluginIds,
  }) async {
    if (!enabled || text.isEmpty) {
      return PluginProcessResult(processedText: text, events: []);
    }

    await StickerLibrary.ensureLoaded();
    final packIds = StickerPackGrants.effective(
      rolePluginIds,
      StickerRegistry.instance.packIds,
    );
    final events = <PluginEvent>[];
    final processedText = _convert(text, events, packIds, topLevel: true)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    return PluginProcessResult(
      processedText: processedText,
      events: events,
    );
  }

  String _convert(
    String text,
    List<PluginEvent> events,
    Set<String>? packIds, {
    required bool topLevel,
  }) {
    final kept = StringBuffer();
    for (final segment in firstPartyContentTagScanner.scan(text)) {
      if (segment is! ContentTagElement) {
        kept.write(segment.raw);
      } else if (StickerTag.isElement(segment)) {
        if (topLevel) {
          _emitSticker(StickerTag.tagOf(segment), events, packIds);
        }
        // 成对写法的正文仍是文字，只去掉标签外壳
        if (!segment.selfClosing) {
          kept.write(
            _convert(segment.inner, events, packIds, topLevel: false),
          );
        }
      } else {
        // 语音、图片等标签保留外壳，里面的表情标签照样删掉
        kept.write(
          '${segment.openTag}'
          '${_convert(segment.inner, events, packIds, topLevel: false)}'
          '${segment.closeTag}',
        );
      }
    }
    return kept.toString();
  }

  void _emitSticker(
    String tag,
    List<PluginEvent> events,
    Set<String>? packIds,
  ) {
    final sticker = StickerRegistry.instance.getByTag(tag, packIds: packIds);
    if (sticker == null) return;
    events.add(PluginEvent(
      pluginId: id,
      type: 'sticker_convert',
      data: {
        'tag': tag,
        'stickerId': sticker.id,
        'assetPath': sticker.path,
        'description': sticker.description,
      },
    ));
    unawaited(StickerLibrary.markUsedIfLoaded(sticker.id));
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

/// 聊天插件设置页面
///
/// 整合所有聊天相关插件的入口：
/// - 记忆库、表情包、主动关怀、语音设置、绘图设置
import 'package:aicove_flutter/src/ui/shared/widgets/moe_page_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/moe_app_bar.dart';
import '../../../../ui/shared/widgets/list/moe_settings_group.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../../../../features/settings/app_settings.dart';
import '../../plugins/pages/image_plugin_detail_page.dart';
import 'context_memory_settings_page.dart';
import '../../plugins/pages/time_awareness_plugin_detail_page.dart';
import '../../plugins/pages/tts_plugin_detail_page.dart';
import '../../plugins/pages/sticker_settings_page.dart';
import '../../plugins/pages/tavern_plugin_detail_page.dart';
import '../../auto_reply/pages/auto_reply_settings_page.dart';
import '../../../../ui/shared/widgets/moe_scroll_edge.dart';

/// 聊天插件配置项
class ChatPluginItem {
  final String id;
  final String name;
  final String subtitle;
  final IconData icon;
  final Widget? page;
  final bool conversationSelectable;

  const ChatPluginItem({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.icon,
    this.page,
    this.conversationSelectable = true,
  });
}

/// 聊天插件列表（全局定义，供角色插件选择使用）
const chatPluginItems = [
  ChatPluginItem(
    id: 'memory',
    name: '记忆库',
    subtitle: '长期记忆设置',
    icon: Icons.psychology_outlined,
  ),
  ChatPluginItem(
    id: 'trigger',
    name: '主动关怀',
    subtitle: '主动回复',
    icon: Icons.favorite_outline,
  ),
  ChatPluginItem(
    id: 'sticker',
    name: '表情包',
    subtitle: '表情包管理',
    icon: Icons.emoji_emotions_outlined,
  ),
  ChatPluginItem(
    id: 'tts',
    name: '语音设置',
    subtitle: '音色、朗读',
    icon: Icons.record_voice_over_outlined,
  ),
  ChatPluginItem(
    id: 'image',
    name: '绘图设置',
    subtitle: '生图模型',
    icon: Icons.brush_outlined,
  ),
  ChatPluginItem(
    id: 'tavern_compatibility',
    name: '酒馆兼容插件（测试）',
    subtitle: '预设、正则、世界书',
    icon: Icons.menu_book_outlined,
    // 使用角色现有 recipeId 单独绑定，不伪装成工具权限开关。
    conversationSelectable: false,
  ),
  ChatPluginItem(
    id: 'time_awareness',
    name: '时间感知',
    subtitle: '当前时间、消息时间线',
    icon: Icons.schedule_outlined,
  ),
];

final List<ChatPluginItem> conversationScopedChatPluginItems = chatPluginItems
    .where((item) => item.conversationSelectable)
    .toList(growable: false);

class ChatPluginSettingsPage extends ConsumerWidget {
  const ChatPluginSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;

    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const MoeAppBar(title: '聊天插件', showBackButton: true),
      backgroundColor: colors.surface,
      body: MoeSettingsContent(
        child: Builder(
          builder: (context) => ListView(
            padding: moeUnderBarPadding(
              context,
              MoeSettingsLayout.verticalListPadding,
            ),
            children: [
              MoeSettingsGroup(
                children: [
                  for (
                    var index = 0;
                    index < chatPluginItems.length;
                    index++
                  ) ...[
                    if (index > 0)
                      Divider(
                        height: borderWidth,
                        thickness: borderWidth,
                        color: colors.borderLight,
                      ),
                    Builder(
                      builder: (context) {
                        final item = chatPluginItems[index];
                        final isEnabled = _isPluginEnabled(ref, item.id);

                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                          ),
                          title: Text(
                            item.name,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: MoeFontWeights.emphasis,
                              color: colors.text,
                            ),
                          ),
                          subtitle: Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                item.subtitle,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: colors.muted,
                                ),
                              ),
                              if (isEnabled != null)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: MoeG2Decoration(
                                    radius: 4,
                                    color: isEnabled
                                        ? colors.primary.withOpacity(0.1)
                                        : colors.muted.withOpacity(0.1),
                                  ),
                                  child: Text(
                                    isEnabled ? '已启用' : '已禁用',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: isEnabled
                                          ? colors.primary
                                          : colors.muted,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          trailing: Icon(
                            Icons.chevron_right,
                            color: colors.muted,
                          ),
                          onTap: () => _navigateToPlugin(context, item),
                        );
                      },
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 获取插件启用状态；只有保留全局开关的主动关怀返回状态，
  /// 其余插件常开、由角色卡选择控制，不显示徽标
  bool? _isPluginEnabled(WidgetRef ref, String pluginId) {
    switch (pluginId) {
      case 'trigger':
        return ref.watch(appSettingsProvider).value?.autoReplySettings.enabled;
      default:
        return null;
    }
  }

  /// 导航到插件详情页
  void _navigateToPlugin(BuildContext context, ChatPluginItem item) {
    Widget? page;
    switch (item.id) {
      case 'tavern_compatibility':
        page = const TavernPluginDetailPage();
        break;
      case 'memory':
        page = const ContextMemorySettingsPage();
        break;
      case 'sticker':
        page = const StickerSettingsPage();
        break;
      case 'trigger':
        page = const AutoReplySettingsPage();
        break;
      case 'tts':
        page = const TtsPluginDetailPage();
        break;
      case 'image':
        page = const ImagePluginDetailPage();
        break;
      case 'time_awareness':
        page = const TimeAwarenessPluginDetailPage();
        break;
    }

    if (page != null) {
      Navigator.of(context).push(ParallaxSlidePageRoute(page: page));
    }
  }
}

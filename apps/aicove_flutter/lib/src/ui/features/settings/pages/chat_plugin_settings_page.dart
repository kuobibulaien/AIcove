/// 聊天插件设置页面
///
/// 整合所有聊天相关插件的入口：
/// - 记忆库、主动关怀、表情包、语音设置、绘图设置、时间感知、联网搜索、酒馆相关
import 'package:aicove_flutter/src/ui/shared/widgets/moe_page_scaffold.dart';
import 'package:flutter/material.dart';

import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/moe_app_bar.dart';
import '../../../../ui/shared/widgets/list/moe_settings_group.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../../plugins/pages/image_plugin_detail_page.dart';
import 'context_memory_settings_page.dart';
import '../../plugins/pages/time_awareness_plugin_detail_page.dart';
import '../../plugins/pages/tts_plugin_detail_page.dart';
import '../../plugins/pages/sticker_settings_page.dart';
import '../../plugins/pages/tavern_plugin_detail_page.dart';
import '../../plugins/pages/plugin_prompts_page.dart';
import '../../plugins/pages/web_search_plugin_detail_page.dart';
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
    id: 'time_awareness',
    name: '时间感知',
    subtitle: '当前时间、消息时间线',
    icon: Icons.schedule_outlined,
  ),
  ChatPluginItem(
    id: 'web_search',
    name: '联网搜索',
    subtitle: '多家搜索供应商',
    icon: Icons.travel_explore,
  ),
  ChatPluginItem(
    id: 'tavern_compatibility',
    name: '酒馆相关',
    subtitle: '预设、正则、世界书',
    icon: Icons.menu_book_outlined,
    // 使用角色现有 recipeId 单独绑定，不伪装成工具权限开关。
    conversationSelectable: false,
  ),
];

final List<ChatPluginItem> conversationScopedChatPluginItems = chatPluginItems
    .where((item) => item.conversationSelectable)
    .toList(growable: false);

class ChatPluginSettingsPage extends StatelessWidget {
  const ChatPluginSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
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

                        return _buildEntryTile(
                          colors: colors,
                          title: item.name,
                          subtitle: item.subtitle,
                          onTap: () => _navigateToPlugin(context, item),
                        );
                      },
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 16),
              MoeSettingsGroup(
                children: [
                  _buildEntryTile(
                    colors: colors,
                    title: PluginPromptsPage.title,
                    subdued: true,
                    subtitle: '插件标签说明，所有角色共用',
                    onTap: () => Navigator.of(context).push(
                      ParallaxSlidePageRoute(page: const PluginPromptsPage()),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 聊天插件页入口行；[subdued] 用于全局工具提示词这类辅助入口，弱化标题存在感
  Widget _buildEntryTile({
    required MoeColors colors,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool subdued = false,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 15,
          fontWeight: subdued ? MoeFontWeights.normal : MoeFontWeights.emphasis,
          fontStyle: subdued ? FontStyle.italic : FontStyle.normal,
          color: subdued ? colors.textSecondary : colors.text,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 13, color: colors.muted),
      ),
      trailing: Icon(Icons.chevron_right, color: colors.muted),
      onTap: onTap,
    );
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
      case 'web_search':
        page = const WebSearchPluginDetailPage();
        break;
    }

    if (page != null) {
      Navigator.of(context).push(ParallaxSlidePageRoute(page: page));
    }
  }
}

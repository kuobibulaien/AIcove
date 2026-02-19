/// 聊天插件设置页面
///
/// 整合所有聊天相关插件的入口：
/// - 记忆库、表情包、主动关怀、语音设置、绘图设置
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/moe_app_bar.dart';
import '../../../../ui/shared/widgets/moe_toast.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../../../../features/plugins/plugin_providers.dart';
import '../../../../features/settings/app_settings.dart';
import '../../plugins/pages/memory_plugin_detail_page.dart';
import '../../plugins/pages/tts_plugin_detail_page.dart';
import '../../plugins/pages/sticker_settings_page.dart';
import '../../auto_reply/pages/auto_reply_settings_page.dart';

/// 聊天插件配置项
class ChatPluginItem {
  final String id;
  final String name;
  final String subtitle;
  final IconData icon;
  final Widget? page;

  const ChatPluginItem({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.icon,
    this.page,
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
    id: 'sticker',
    name: '表情包',
    subtitle: '表情包管理',
    icon: Icons.emoji_emotions_outlined,
  ),
  ChatPluginItem(
    id: 'trigger',
    name: '主动关怀',
    subtitle: '主动回复触发器',
    icon: Icons.favorite_outline,
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
];

class ChatPluginSettingsPage extends ConsumerWidget {
  const ChatPluginSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;

    return Scaffold(
      appBar: const MoeAppBar(title: '聊天插件', showBackButton: true),
      backgroundColor: colors.surface,
      body: ListView.separated(
        itemCount: chatPluginItems.length,
        separatorBuilder: (_, __) => Divider(height: borderWidth, thickness: borderWidth, color: colors.borderLight),
        itemBuilder: (context, index) {
          final item = chatPluginItems[index];
          final isEnabled = _isPluginEnabled(ref, item.id);

          return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            minLeadingWidth: 24,
            horizontalTitleGap: 12,
            leading: Icon(item.icon, color: colors.text, size: 24),
            title: Text(item.name, style: TextStyle(fontSize: 15, fontWeight: MoeFontWeights.emphasis, color: colors.text)),
            subtitle: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(item.subtitle, style: TextStyle(fontSize: 13, color: colors.muted)),
                if (isEnabled != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: MoeG2Decoration(
                      radius: 4,
                      color: isEnabled ? colors.primary.withOpacity(0.1) : colors.muted.withOpacity(0.1),
                    ),
                    child: Text(
                      isEnabled ? '已启用' : '已禁用',
                      style: TextStyle(fontSize: 10, color: isEnabled ? colors.primary : colors.muted),
                    ),
                  ),
              ],
            ),
            trailing: Icon(Icons.chevron_right, color: colors.muted),
            onTap: () => _navigateToPlugin(context, item),
          );
        },
      ),
    );
  }

  /// 获取插件启用状态
  bool? _isPluginEnabled(WidgetRef ref, String pluginId) {
    switch (pluginId) {
      case 'memory':
        return ref.watch(memoryPluginConfigProvider).enabled;
      case 'tts':
        return ref.watch(ttsPluginConfigProvider).enabled;
      case 'trigger':
        return ref.watch(triggerPluginConfigProvider).enabled;
      case 'sticker':
        return ref.watch(stickerPluginConfigProvider).enabled;
      case 'image':
        return ref.watch(appSettingsProvider).value?.imageGenerationEnabled;
      default:
        return null; // 未实现的插件不显示状态
    }
  }

  /// 导航到插件详情页
  void _navigateToPlugin(BuildContext context, ChatPluginItem item) {
    Widget? page;
    switch (item.id) {
      case 'memory':
        page = const MemoryPluginDetailPage();
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
        MoeToast.brief(context, '绘图设置功能开发中');
        return;
    }

    if (page != null) {
      Navigator.of(context).push(ParallaxSlidePageRoute(page: page));
    }
  }
}

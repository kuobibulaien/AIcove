import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/utils/message_formatter.dart';
import '../../../../core/widgets/parallax_slide_page_route.dart';
import '../../../settings/app_settings.dart';
import 'chunk_settings_page.dart';
import 'sticker_settings_page.dart';

/// 自然回复设置页面
/// 
/// 功能区：
/// 1. 消息分段 - 启用/过滤开关，点击进入详细设置
/// 2. 表情包 - 管理入口
class MessageFormatSettingsPage extends ConsumerStatefulWidget {
  const MessageFormatSettingsPage({super.key});

  @override
  ConsumerState<MessageFormatSettingsPage> createState() => _MessageFormatSettingsPageState();
}

class _MessageFormatSettingsPageState extends ConsumerState<MessageFormatSettingsPage> {
  MessageFormatConfig? _config;
  bool _initialized = false;

  void _initializeConfig(MessageFormatConfig config) {
    if (!_initialized) {
      _config = config;
      _initialized = true;
    }
  }

  Future<void> _updateConfig(MessageFormatConfig newConfig) async {
    setState(() => _config = newConfig);
    await ref.read(appSettingsProvider.notifier).updateMessageFormatConfig(newConfig);
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final colors = context.moeColors;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: colors.surface,
        foregroundColor: colors.text,
        elevation: 0,
        title: Text('自然回复', style: TextStyle(color: colors.text)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(borderWidth),
          child: Container(color: colors.borderLight, height: borderWidth),
        ),
      ),
      backgroundColor: colors.surface,
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
        data: (settings) {
          _initializeConfig(settings.messageFormatConfig);
          final currentConfig = _config ?? const MessageFormatConfig();

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // ========== 消息分段 ==========
              _buildSectionHeader('消息分段', colors),
              Card(
                color: colors.surfaceAlt,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Column(
                  children: [
                    ListTile(
                      leading: Icon(Icons.segment, color: colors.primary),
                      title: const Text('消息分段', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                      subtitle: Text(
                        currentConfig.enableChunking ? '已开启' : '已关闭',
                        style: TextStyle(fontSize: 13, color: colors.muted),
                      ),
                      trailing: Icon(Icons.arrow_forward_ios, size: 16, color: colors.muted),
                      onTap: () => Navigator.of(context).push(ParallaxSlidePageRoute(page: const ChunkSettingsPage())),
                    ),
                    Divider(height: 0, thickness: borderWidth, color: colors.divider),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      child: Text(
                        '模拟真实聊天，按标点符号自动将长消息拆分成多条发送。',
                        style: TextStyle(fontSize: 12, color: colors.muted),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // ========== 表情包 ==========
              _buildSectionHeader('表情包', colors),
              Card(
                color: colors.surfaceAlt,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Column(
                  children: [
                    ListTile(
                      leading: Icon(Icons.emoji_emotions, color: colors.primary),
                      title: const Text('表情包管理', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                      subtitle: Text('按标签分组查看和管理', style: TextStyle(fontSize: 13, color: colors.muted)),
                      trailing: Icon(Icons.arrow_forward_ios, size: 16, color: colors.muted),
                      onTap: () => Navigator.of(context).push(ParallaxSlidePageRoute(page: const StickerSettingsPage())),
                    ),
                    Divider(height: 0, thickness: borderWidth, color: colors.divider),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      child: Text(
                        'AI 使用 [标签] 语法发送表情包，如 [晚安]、[抱抱]。同义词自动匹配。',
                        style: TextStyle(fontSize: 12, color: colors.muted),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSectionHeader(String title, MoeColors colors) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: TextStyle(color: colors.textSecondary, fontWeight: FontWeight.w600, fontSize: 13),
      ),
    );
  }
}

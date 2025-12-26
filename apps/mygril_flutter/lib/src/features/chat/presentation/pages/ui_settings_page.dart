import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/tokens.dart';
import '../../../settings/app_settings.dart';

/// 界面设置页面
class UiSettingsPage extends ConsumerWidget {
  const UiSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final colors = context.moeColors;

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        // 暗色适配：顶部栏使用主题色，避免白底刺眼
        backgroundColor: colors.headerColor,
        foregroundColor: colors.headerContentColor,
        elevation: 0,
        // 添加底部分割线
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(borderWidth),
          child: Container(
            color: colors.borderLight,
            height: borderWidth,
          ),
        ),
      ),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载设置失败: $e')),
        data: (settings) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // 暗色模式设置
              Container(
                decoration: BoxDecoration(
                  color: colors.panel,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: colors.border,
                    width: 1,
                  ),
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.dark_mode_outlined, color: colors.text, size: 24),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '深色模式',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: colors.text,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // 深色模式手动开关（一直显示）
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '深色模式',
                        style: TextStyle(fontSize: 15, color: colors.text),
                      ),
                      subtitle: Text(
                        settings.useSystemTheme ? '当前跟随系统设置' : '手动控制',
                        style: TextStyle(fontSize: 13, color: colors.muted),
                      ),
                      trailing: Switch(
                        value: settings.isDarkMode,
                        activeColor: colors.primary,
                        onChanged: (value) {
                          // 点击手动开关时，同时设置暗色模式和关闭「跟随系统」
                          ref.read(appSettingsProvider.notifier).setDarkModeAndSystemTheme(
                            isDark: value,
                            useSystem: false,
                          );
                        },
                      ),
                    ),
                    Divider(height: 1, color: colors.divider),
                    // 跟随系统主题
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '跟随系统',
                        style: TextStyle(fontSize: 15, color: colors.text),
                      ),
                      subtitle: Text(
                        '自动切换浅色/深色模式',
                        style: TextStyle(fontSize: 13, color: colors.muted),
                      ),
                      trailing: Switch(
                        value: settings.useSystemTheme,
                        activeColor: colors.primary,
                        onChanged: (value) {
                          ref
                              .read(appSettingsProvider.notifier)
                              .setUseSystemTheme(value);
                        },
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // 消息字体大小设置
              Container(
                decoration: BoxDecoration(
                  color: colors.panel,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: colors.border,
                    width: 1,
                  ),
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.text_fields, color: colors.text, size: 24),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '消息字体大小',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: colors.text,
                            ),
                          ),
                        ),
                        // 显示当前字号
                        Text(
                          settings.messageFontSize.toStringAsFixed(1),
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: colors.primary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Text(
                          '较小',
                          style: TextStyle(fontSize: 12, color: colors.muted),
                        ),
                        Expanded(
                          child: Slider(
                            value: settings.messageFontSize.clamp(12.0, 20.0),
                            min: 12.0,
                            max: 20.0,
                            divisions: 16, // 步进 0.5
                            activeColor: colors.primary,
                            onChanged: (value) {
                              ref
                                  .read(appSettingsProvider.notifier)
                                  .setMessageFontSize(value);
                            },
                          ),
                        ),
                        Text(
                          '较大',
                          style: TextStyle(fontSize: 12, color: colors.muted),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // 背景色设置
              Container(
                decoration: BoxDecoration(
                  color: colors.panel,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: colors.border,
                    width: 1,
                  ),
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.palette, color: colors.text, size: 24),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '聊天背景色',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: colors.text,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: ChatBackgroundColor.values.map((color) {
                        final isSelected = settings.chatBackgroundColor == color;
                        return Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: GestureDetector(
                              onTap: () {
                                ref
                                    .read(appSettingsProvider.notifier)
                                    .setChatBackgroundColor(color);
                              },
                              child: Container(
                                height: 80,
                                decoration: BoxDecoration(
                                  color: color.color,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: isSelected ? colors.primary : colors.border,
                                    width: isSelected ? 3 : 1,
                                  ),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    if (isSelected)
                                      Icon(
                                        Icons.check_circle,
                                        color: colors.primary,
                                        size: 32,
                                      ),
                                    const SizedBox(height: 4),
                                    Text(
                                      color.label,
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                                        color: colors.text,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

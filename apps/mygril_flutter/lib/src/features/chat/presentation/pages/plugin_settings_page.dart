import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/tokens.dart';
import '../../../plugins/plugin_providers.dart';
import 'tts_plugin_detail_page.dart';

/// 插件设置页面
class PluginSettingsPage extends ConsumerWidget {
  const PluginSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pluginManager = ref.watch(pluginManagerProvider);
    final allPlugins = pluginManager.getAllPlugins();
    final colors = context.moeColors;

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        backgroundColor: colors.surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: colors.text),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          '插件设置',
          style: TextStyle(
            color: colors.text,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: allPlugins.length,
        separatorBuilder: (context, index) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final plugin = allPlugins[index];
          return _buildPluginListItem(context, plugin);
        },
      ),
    );
  }

  /// 构建插件列表项
  Widget _buildPluginListItem(BuildContext context, dynamic plugin) {
    final colors = context.moeColors;
    return Container(
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colors.border,
          width: 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            _navigateToPluginDetail(context, plugin);
          },
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // 插件图标
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: colors.primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    plugin.icon,
                    color: colors.primary,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),

                // 插件名称（居左）
                Expanded(
                  child: Text(
                    plugin.name,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),

                // 已开启/已关闭状态（居右）
                Text(
                  plugin.enabled ? '已开启' : '已关闭',
                  style: TextStyle(
                    color: plugin.enabled ? colors.primary : colors.textSecondary,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 8),

                // 箭头图标
                Icon(
                  Icons.arrow_forward_ios,
                  color: colors.textSecondary,
                  size: 16,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 导航到插件详细设置页面
  void _navigateToPluginDetail(BuildContext context, dynamic plugin) {
    // 根据插件 ID 导航到对应的详细设置页面
    switch (plugin.id) {
      case 'tts':
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => const TtsPluginDetailPage(),
          ),
        );
        break;
      // 未来可以添加更多插件的详细页面
      default:
        // 显示提示
        final colors = context.moeColors;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('该插件暂无详细设置'),
            backgroundColor: colors.panel,
          ),
        );
    }
  }
}

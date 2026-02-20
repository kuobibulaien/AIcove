import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/theme/accent_color_provider.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';

/// 预设颜色列表
const _presetColors = [
  Color(0xFFFC96AA), // 粉红
  Color(0xFF4A90E2), // 淡蓝
  Color(0xFF4ECDC4), // 薄荷
  Color(0xFFB39DDB), // 薰衣草
  Color(0xFFFF8A65), // 珊瑚
  Color(0xFFFFD54F), // 金黄
  Color(0xFF81C784), // 草绿
];

/// 界面设置页面
///
/// 使用 MoeSettingsGroup 统一样式重构
class UiSettingsPage extends ConsumerWidget {
  const UiSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final colors = context.moeColors;

    return Scaffold(
      appBar: const MoeAppBar(
        title: '界面设置',
        showBackButton: true,
      ),
      body: settingsAsync.when(
        loading: () => const Center(child: MoeLoadingIndicator()),
        error: (e, _) => Center(child: Text('加载设置失败: $e')),
        data: (settings) => _buildContent(context, ref, settings, colors),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
    MoeColors colors,
  ) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ========== 主题色设置 ==========
        _buildSectionTitle(context, '主题色'),
        const SizedBox(height: 12),
        MoeSettingsGroup(
          margin: EdgeInsets.zero,
          children: [
            _buildAccentColorPicker(context, ref, settings, colors),
          ],
        ),

        const SizedBox(height: 24),

        // ========== 深色模式设置 ==========
        _buildSectionTitle(context, '深色模式'),
        const SizedBox(height: 12),
        MoeSettingsGroup(
          margin: EdgeInsets.zero,
          children: [
            MoeSettingsRow(
              icon: Icons.dark_mode_outlined,
              label: '深色模式',
              subtitle: settings.useSystemTheme ? '当前跟随系统设置' : '手动控制',
              trailingType: MoeSettingsRowTrailing.switchControl,
              switchValue: settings.isDarkMode,
              onSwitchChanged: (value) {
                ref
                    .read(appSettingsProvider.notifier)
                    .setDarkModeAndSystemTheme(
                      isDark: value,
                      useSystem: false,
                    );
              },
            ),
            MoeSettingsRow(
              icon: Icons.sync,
              label: '跟随系统',
              subtitle: '自动切换浅色/深色模式',
              trailingType: MoeSettingsRowTrailing.switchControl,
              switchValue: settings.useSystemTheme,
              onSwitchChanged: (value) {
                ref.read(appSettingsProvider.notifier).setUseSystemTheme(value);
              },
            ),
          ],
        ),

        const SizedBox(height: 24),

        // ========== 全局字体大小设置 ==========
        _buildSectionTitle(context, '字体大小'),
        const SizedBox(height: 12),
        MoeSettingsGroup(
          margin: EdgeInsets.zero,
          children: [
            _buildTextScaleSlider(context, ref, settings, colors),
          ],
        ),

        const SizedBox(height: 24),

        // ========== 全局界面缩放设置 ==========
        _buildSectionTitle(context, '界面缩放'),
        const SizedBox(height: 12),
        MoeSettingsGroup(
          margin: EdgeInsets.zero,
          children: [
            _buildUiScaleSlider(context, ref, settings, colors),
          ],
        ),

        const SizedBox(height: 24),

        // ========== 聊天背景色设置 ==========
        _buildSectionTitle(context, '聊天背景色'),
        const SizedBox(height: 12),
        MoeSettingsGroup(
          margin: EdgeInsets.zero,
          children: [
            _buildBackgroundColorPicker(context, ref, settings, colors),
          ],
        ),

        const SizedBox(height: 24),

        // ========== 聊天界面设置 ==========
        _buildSectionTitle(context, '聊天界面'),
        const SizedBox(height: 12),
        MoeSettingsGroup(
          margin: EdgeInsets.zero,
          children: [
            MoeSettingsRow(
              icon: Icons.account_circle_outlined,
              label: '隐藏用户头像',
              subtitle: '隐藏后消息气泡将贴着屏幕边缘',
              trailingType: MoeSettingsRowTrailing.switchControl,
              switchValue: settings.hideUserAvatar,
              onSwitchChanged: (value) {
                ref.read(appSettingsProvider.notifier).setHideUserAvatar(value);
              },
            ),
          ],
        ),

        const SizedBox(height: 24),

        // ========== 消息分段设置 ==========
        _buildSectionTitle(context, '消息分段'),
        const SizedBox(height: 12),
        MoeSettingsGroup(
          margin: EdgeInsets.zero,
          children: [
            MoeSettingsRow(
              icon: Icons.segment,
              label: '启用消息分段',
              subtitle: '按标点符号自动分段显示 AI 回复',
              trailingType: MoeSettingsRowTrailing.switchControl,
              switchValue: settings.messageFormatConfig.enableChunking,
              onSwitchChanged: (value) async {
                final newConfig = settings.messageFormatConfig
                    .copyWith(enableChunking: value);
                await ref
                    .read(appSettingsProvider.notifier)
                    .updateMessageFormatConfig(newConfig);
              },
            ),
            MoeSettingsRow(
              icon: Icons.filter_alt_outlined,
              label: '过滤句末标点',
              subtitle: '移除分段后末尾的标点符号',
              trailingType: MoeSettingsRowTrailing.switchControl,
              switchValue: settings.messageFormatConfig.filterPunctuation,
              onSwitchChanged: (value) async {
                final newConfig = settings.messageFormatConfig
                    .copyWith(filterPunctuation: value);
                await ref
                    .read(appSettingsProvider.notifier)
                    .updateMessageFormatConfig(newConfig);
              },
            ),
          ],
        ),
        if (settings.messageFormatConfig.enableChunking) ...[
          const SizedBox(height: 12),
          _buildChunkPunctuationEditor(context, ref, settings, colors),
        ],

        const SizedBox(height: 32),
      ],
    );
  }

  /// 构建分区标题
  Widget _buildSectionTitle(BuildContext context, String title) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: MoeFontWeights.emphasis,
          ),
    );
  }

  /// 主题色选择器（点击展开色板弹窗）
  Widget _buildAccentColorPicker(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
    MoeColors colors,
  ) {
    final currentColor = ref.watch(accentColorProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 预设颜色 + 自定义按钮
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              ..._presetColors.map((color) {
                final isSelected =
                    (currentColor.value & 0xFFFFFF) == (color.value & 0xFFFFFF);
                return GestureDetector(
                  onTap: () => ref.setAccentColor(color),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isSelected ? colors.text : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: isSelected
                        ? const Icon(Icons.check, color: Colors.white, size: 18)
                        : null,
                  ),
                );
              }),
              // 自定义颜色按钮
              GestureDetector(
                onTap: () => _showColorPickerDialog(context, ref, currentColor),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    gradient: const SweepGradient(
                      colors: [
                        Colors.red,
                        Colors.yellow,
                        Colors.green,
                        Colors.cyan,
                        Colors.blue,
                        Colors.purple,
                        Colors.red
                      ],
                    ),
                    shape: BoxShape.circle,
                    border: Border.all(color: colors.border, width: 1),
                  ),
                  child:
                      const Icon(Icons.colorize, color: Colors.white, size: 18),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '点击预设颜色快速切换，或点击彩色按钮自定义',
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
        ],
      ),
    );
  }

  /// 显示颜色选择器弹窗
  void _showColorPickerDialog(
      BuildContext context, WidgetRef ref, Color currentColor) {
    var pickerColor = currentColor;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择主题色'),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: pickerColor,
            onColorChanged: (color) => pickerColor = color,
            enableAlpha: false,
            hexInputBar: true,
            labelTypes: const [],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              ref.setAccentColor(pickerColor);
              Navigator.of(context).pop();
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  /// 全局字体大小滑块（支持点击数字手动输入）
  Widget _buildTextScaleSlider(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
    MoeColors colors,
  ) {
    const minScale = kMinTextScaleFactor;
    const maxScale = kMaxTextScaleFactor;
    final scale = settings.textScaleFactor.clamp(minScale, maxScale).toDouble();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.format_size, size: 20, color: colors.textSecondary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '全局字体大小',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: MoeFontWeights.emphasis,
                    color: colors.text,
                  ),
                ),
              ),
              // 点击可手动输入
              GestureDetector(
                onTap: () => _showScaleInputDialog(context, ref, scale, colors),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: MoeG2Decoration(
                    radius: 6,
                    color: colors.accentColor.withValues(alpha: 0.15),
                  ),
                  child: Text(
                    scale.toStringAsFixed(2),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: MoeFontWeights.emphasis,
                      color: colors.accentColor,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('较小',
                  style: TextStyle(fontSize: 12, color: colors.textSecondary)),
              Expanded(
                child: Slider(
                  value: scale,
                  min: minScale,
                  max: maxScale,
                  divisions: 14, // 0.05 步长：(1.5-0.8)/0.05 = 14
                  activeColor: colors.accentColor,
                  onChanged: (value) {
                    ref
                        .read(appSettingsProvider.notifier)
                        .setTextScaleFactor(value);
                  },
                ),
              ),
              Text('较大',
                  style: TextStyle(fontSize: 12, color: colors.textSecondary)),
            ],
          ),
        ],
      ),
    );
  }

  /// 弹窗手动输入缩放值
  void _showScaleInputDialog(
    BuildContext context,
    WidgetRef ref,
    double currentScale,
    MoeColors colors,
  ) {
    final controller =
        TextEditingController(text: currentScale.toStringAsFixed(2));
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('输入字体缩放值'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                hintText: '范围 0.80 ~ 1.50',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
            const SizedBox(height: 8),
            Text(
              '1.00 为默认大小，0.80 最小，1.50 最大',
              style: TextStyle(fontSize: 12, color: colors.muted),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final value = double.tryParse(controller.text);
              if (value != null) {
                ref.read(appSettingsProvider.notifier).setTextScaleFactor(
                      value.clamp(kMinTextScaleFactor, kMaxTextScaleFactor),
                    );
              }
              Navigator.of(context).pop();
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  /// 全局界面缩放滑块（作用于布局和组件大小）
  Widget _buildUiScaleSlider(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
    MoeColors colors,
  ) {
    const minScale = kMinUiScaleFactor;
    const maxScale = kMaxUiScaleFactor;
    final scale = settings.uiScaleFactor.clamp(minScale, maxScale).toDouble();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.zoom_out_map, size: 20, color: colors.textSecondary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '全局界面缩放',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: MoeFontWeights.emphasis,
                    color: colors.text,
                  ),
                ),
              ),
              GestureDetector(
                onTap: () =>
                    _showUiScaleInputDialog(context, ref, scale, colors),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: MoeG2Decoration(
                    radius: 6,
                    color: colors.accentColor.withValues(alpha: 0.15),
                  ),
                  child: Text(
                    scale.toStringAsFixed(2),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: MoeFontWeights.emphasis,
                      color: colors.accentColor,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('较小',
                  style: TextStyle(fontSize: 12, color: colors.textSecondary)),
              Expanded(
                child: Slider(
                  value: scale,
                  min: minScale,
                  max: maxScale,
                  divisions: 7, // 0.05 步长：(1.20-0.85)/0.05 = 7
                  activeColor: colors.accentColor,
                  onChanged: (value) {
                    ref
                        .read(appSettingsProvider.notifier)
                        .setUiScaleFactor(value);
                  },
                ),
              ),
              Text('较大',
                  style: TextStyle(fontSize: 12, color: colors.textSecondary)),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '用于微调整体界面大小（推荐 0.95~1.05）',
            style: TextStyle(fontSize: 12, color: colors.muted),
          ),
        ],
      ),
    );
  }

  /// 弹窗手动输入界面缩放值
  void _showUiScaleInputDialog(
    BuildContext context,
    WidgetRef ref,
    double currentScale,
    MoeColors colors,
  ) {
    final controller =
        TextEditingController(text: currentScale.toStringAsFixed(2));
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('输入界面缩放值'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                hintText: '范围 0.85 ~ 1.20',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
            const SizedBox(height: 8),
            Text(
              '1.00 为默认大小，建议在 0.95 ~ 1.05 间微调',
              style: TextStyle(fontSize: 12, color: colors.muted),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final value = double.tryParse(controller.text);
              if (value != null) {
                ref.read(appSettingsProvider.notifier).setUiScaleFactor(
                      value.clamp(kMinUiScaleFactor, kMaxUiScaleFactor),
                    );
              }
              Navigator.of(context).pop();
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  /// 聊天背景色选择器（自定义内容）
  Widget _buildBackgroundColorPicker(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
    MoeColors colors,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Row(
        children: ChatBackgroundColor.values.map((option) {
          final isSelected = settings.chatBackgroundColor == option;
          // 默认色使用全局背景色预览
          final displayColor = option.color ?? colors.surface;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: GestureDetector(
                onTap: () {
                  ref
                      .read(appSettingsProvider.notifier)
                      .setChatBackgroundColor(option);
                },
                child: Container(
                  height: 72,
                  decoration: MoeG2Decoration(
                    radius: 10,
                    color: displayColor,
                    border: Border.all(
                      color: isSelected ? colors.accentColor : colors.border,
                      width: isSelected ? 2.5 : 1,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (isSelected)
                        Icon(Icons.check_circle,
                            color: colors.accentColor, size: 28),
                      const SizedBox(height: 4),
                      Text(
                        option.label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: isSelected
                              ? MoeFontWeights.emphasis
                              : MoeFontWeights.normal,
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
    );
  }

  /// 分段标点编辑器
  Widget _buildChunkPunctuationEditor(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
    MoeColors colors,
  ) {
    final config = settings.messageFormatConfig;

    return MoeSettingsGroup(
      margin: EdgeInsets.zero,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '分段标点',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: MoeFontWeights.emphasis,
                  color: colors.text,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '遇到以下标点时分段（用空格分隔多个标点）',
                style: TextStyle(fontSize: 13, color: colors.muted),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildPunctuationChip(context, ref, settings, colors, '默认',
                      ['。', '！', '？', '，', '、', '；', '…']),
                  _buildPunctuationChip(
                      context, ref, settings, colors, '精简', ['。', '！', '？']),
                  _buildPunctuationChip(context, ref, settings, colors, '详细',
                      ['。', '！', '？', '，', '、', '；', '：', '…']),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: MoeG2Decoration(
                  radius: 8,
                  color: colors.surfaceAlt,
                  border: Border.all(color: colors.borderLight),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: colors.muted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '当前：${config.chunkPunctuations.join(" ")}',
                        style: TextStyle(
                            fontSize: 13, color: colors.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 构建标点预设选择芯片
  Widget _buildPunctuationChip(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
    MoeColors colors,
    String label,
    List<String> punctuations,
  ) {
    final isSelected = _listEquals(
        settings.messageFormatConfig.chunkPunctuations, punctuations);

    return ActionChip(
      label: Text(
        label,
        style: TextStyle(
          color: isSelected ? colors.primary : colors.text,
          fontWeight:
              isSelected ? MoeFontWeights.emphasis : MoeFontWeights.normal,
        ),
      ),
      onPressed: () async {
        final newConfig = settings.messageFormatConfig
            .copyWith(chunkPunctuations: punctuations);
        await ref
            .read(appSettingsProvider.notifier)
            .updateMessageFormatConfig(newConfig);
      },
      backgroundColor: isSelected
          ? colors.primary.withValues(alpha: 0.15)
          : colors.componentBackground,
      side: BorderSide(color: isSelected ? colors.primary : colors.borderLight),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
    );
  }

  /// 比较两个列表是否相等
  bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

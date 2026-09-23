import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/settings/app_settings.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

/// 自定义皮肤的强调色预设。
const _presetColors = [
  Color(0xFFFC96AA), // 粉红
  Color(0xFF4A90E2), // 淡蓝
  Color(0xFF4ECDC4), // 薄荷
  Color(0xFFB39DDB), // 薰衣草
  Color(0xFFFF8A65), // 珊瑚
  Color(0xFFFFD54F), // 金黄
  Color(0xFF81C784), // 草绿
];

String _colorToHex(Color color) =>
    color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase();

/// 自定义皮肤：自由搭配强调色与聊天背景色，任何修改都会切换到自定义皮肤。
class CustomSkinPage extends ConsumerWidget {
  const CustomSkinPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(appSettingsProvider);

    return MoePageScaffold(
      appBar: const MoeAppBar(title: '自定义皮肤', showBackButton: true),
      body: settingsAsync.when(
        loading: () => const Center(child: MoeLoadingIndicator()),
        error: (e, _) => Center(child: Text('加载设置失败: $e')),
        data: (settings) => _buildContent(context, ref, settings),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
  ) {
    final colors = context.moeColors;
    final isActive = settings.interfaceSkin == InterfaceSkin.custom;

    return MoeSettingsContent(
      child: ListView(
        padding: MoeSettingsLayout.verticalListPadding,
        children: [
          MoeSettingsGroup(
            children: [
              if (!isActive) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Text(
                    '当前使用「${settings.interfaceSkin.label}」皮肤，修改任意一项后切换为自定义皮肤。',
                    style: TextStyle(fontSize: 12, color: colors.muted),
                  ),
                ),
              ],
              _buildAccentColorPicker(context, ref, settings, colors),
              Divider(height: 0.5, thickness: 0.5, color: colors.divider),
              _buildBackgroundColorPicker(ref, settings, colors),
            ],
          ),
        ],
      ),
    );
  }

  Widget _blockLabel(MoeColors colors, String label) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 15,
        fontWeight: MoeFontWeights.emphasis,
        color: colors.text,
      ),
    );
  }

  Widget _buildAccentColorPicker(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
    MoeColors colors,
  ) {
    final isActive = settings.interfaceSkin == InterfaceSkin.custom;
    final currentColor = settings.copyWith(
      interfaceSkin: InterfaceSkin.custom,
    ).lightAccentColor;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _blockLabel(colors, '主题色'),
              const Spacer(),
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: currentColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.borderLight),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final color in _presetColors)
                _buildColorSwatch(
                  ref,
                  colors,
                  color,
                  isSelected:
                      isActive &&
                      (currentColor.toARGB32() & 0xFFFFFF) ==
                          (color.toARGB32() & 0xFFFFFF),
                ),
              GestureDetector(
                onTap: () => _showColorPickerDialog(context, ref, currentColor),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    gradient: const SweepGradient(
                      colors: [
                        Colors.red,
                        Colors.yellow,
                        Colors.green,
                        Colors.cyan,
                        Colors.blue,
                        Colors.purple,
                        Colors.red,
                      ],
                    ),
                    shape: BoxShape.circle,
                    border: Border.all(color: colors.borderLight),
                  ),
                  child: const Icon(
                    Icons.colorize,
                    color: Colors.white,
                    size: 16,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildColorSwatch(
    WidgetRef ref,
    MoeColors colors,
    Color color, {
    required bool isSelected,
  }) {
    final checkColor = color.computeLuminance() > 0.55
        ? Colors.black87
        : Colors.white;
    return GestureDetector(
      onTap: () => ref
          .read(appSettingsProvider.notifier)
          .setCustomSkin(accentColor: _colorToHex(color)),
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? colors.text : colors.borderLight,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: isSelected
            ? Icon(Icons.check_rounded, color: checkColor, size: 16)
            : null,
      ),
    );
  }

  void _showColorPickerDialog(
    BuildContext context,
    WidgetRef ref,
    Color currentColor,
  ) {
    var pickerColor = currentColor;
    showMoeBottomSheet<void>(
      context: context,
      title: '选择主题色',
      showCloseButton: true,
      isDismissible: false,
      enableDrag: false,
      builder: (context) => MoeAutoSaveForm(
        snapshot: () => pickerColor.toARGB32(),
        save: () => ref
            .read(appSettingsProvider.notifier)
            .setCustomSkin(accentColor: _colorToHex(pickerColor)),
        builder: (context, update) => SingleChildScrollView(
          child: ColorPicker(
            pickerColor: pickerColor,
            onColorChanged: (color) => update(() => pickerColor = color),
            enableAlpha: false,
            hexInputBar: true,
            labelTypes: const [],
          ),
        ),
      ),
    );
  }

  Widget _buildBackgroundColorPicker(
    WidgetRef ref,
    AppSettings settings,
    MoeColors colors,
  ) {
    final isActive = settings.interfaceSkin == InterfaceSkin.custom;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _blockLabel(colors, '聊天背景色'),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final option in ChatBackgroundColor.values)
                Expanded(
                  child: _buildBackgroundColorTile(
                    ref,
                    colors,
                    option,
                    isSelected:
                        isActive && settings.chatBackgroundColor == option,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBackgroundColorTile(
    WidgetRef ref,
    MoeColors colors,
    ChatBackgroundColor option, {
    required bool isSelected,
  }) {
    final displayColor = option.color ?? colors.surface;
    return GestureDetector(
      onTap: () => ref
          .read(appSettingsProvider.notifier)
          .setCustomSkin(chatBackground: option),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Container(
              height: 44,
              decoration: MoeG2Decoration(
                radius: 12,
                color: displayColor,
                border: Border.all(
                  color: isSelected ? colors.accentColor : colors.borderLight,
                  width: isSelected ? 2 : 1,
                ),
              ),
              child: isSelected
                  ? Center(
                      child: Icon(
                        Icons.check_rounded,
                        color: colors.accentColor,
                        size: 20,
                      ),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                option.label,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected
                      ? MoeFontWeights.emphasis
                      : MoeFontWeights.normal,
                  color: isSelected ? colors.text : colors.textSecondary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/settings/app_settings.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

/// 自定义主题色的预设。
const _presetColors = [
  Color(0xFFFC96AA), // 粉红
  Color(0xFF4A90E2), // 淡蓝
  Color(0xFF4ECDC4), // 薄荷
  Color(0xFFB39DDB), // 薰衣草
  Color(0xFFFF8A65), // 珊瑚
  Color(0xFFFFD54F), // 金黄
  Color(0xFF81C784), // 草绿
];

String _colorToHex(Color color) => color
    .toARGB32()
    .toRadixString(16)
    .padLeft(8, '0')
    .substring(2)
    .toUpperCase();

/// 自定义主题色：浅色、深色模式各选一个主题色，任何修改都会切换到自定义主题色。
class CustomSkinPage extends ConsumerWidget {
  const CustomSkinPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(appSettingsProvider);

    return MoePageScaffold(
      appBar: const MoeAppBar(title: '自定义主题色', showBackButton: true),
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
    final custom = settings.copyWith(interfaceSkin: InterfaceSkin.custom);
    final notifier = ref.read(appSettingsProvider.notifier);
    final divider = Divider(height: 0.5, thickness: 0.5, color: colors.divider);

    return MoeSettingsContent(
      child: ListView(
        padding: MoeSettingsLayout.verticalListPadding,
        children: [
          MoeSettingsGroup(
            children: [
              _buildAccentColorPicker(
                context,
                colors,
                key: 'custom-accent-light',
                label: '浅色模式',
                currentColor: custom.lightAccentColor,
                isActive: isActive,
                onPick: (hex) => notifier.setCustomSkin(accentColor: hex),
              ),
              divider,
              _buildAccentColorPicker(
                context,
                colors,
                key: 'custom-accent-dark',
                label: '深色模式',
                currentColor: custom.darkAccentColor,
                isActive: isActive,
                onPick: (hex) => notifier.setCustomSkin(darkAccentColor: hex),
              ),
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
    MoeColors colors, {
    required String key,
    required String label,
    required Color currentColor,
    required bool isActive,
    required Future<void> Function(String hex) onPick,
  }) {
    return Padding(
      key: ValueKey(key),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _blockLabel(colors, label),
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
          // 预设与取色器排成一行，窄屏时圆点缩小而不换行。
          LayoutBuilder(
            builder: (context, constraints) {
              const count = 8;
              const minGap = 8.0;
              final size =
                  ((constraints.maxWidth - minGap * (count - 1)) / count).clamp(
                    0.0,
                    34.0,
                  );
              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (final color in _presetColors)
                    _buildColorSwatch(
                      colors,
                      color,
                      size: size,
                      onTap: () => onPick(_colorToHex(color)),
                      isSelected:
                          isActive &&
                          (currentColor.toARGB32() & 0xFFFFFF) ==
                              (color.toARGB32() & 0xFFFFFF),
                    ),
                  GestureDetector(
                    onTap: () => _showColorPickerDialog(
                      context,
                      label,
                      currentColor,
                      onPick,
                    ),
                    child: Container(
                      width: size,
                      height: size,
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
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildColorSwatch(
    MoeColors colors,
    Color color, {
    required double size,
    required VoidCallback onTap,
    required bool isSelected,
  }) {
    final checkColor = color.computeLuminance() > 0.55
        ? Colors.black87
        : Colors.white;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
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
    String label,
    Color currentColor,
    Future<void> Function(String hex) onPick,
  ) {
    var pickerColor = currentColor;
    showMoeBottomSheet<void>(
      context: context,
      title: '$label主题色',
      showCloseButton: true,
      builder: (context) => MoeAutoSaveForm(
        snapshot: () => pickerColor.toARGB32(),
        save: () => onPick(_colorToHex(pickerColor)),
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
}

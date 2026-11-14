import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import 'chat_ui_settings_page.dart';
import 'custom_skin_page.dart';
import 'global_wallpaper_edit_page.dart';

bool get _isWindowsDesktop => defaultTargetPlatform == TargetPlatform.windows;

/// 通用设置页面
/// Slider position of the recommended, iOS-closest material step.
const int _kRecommendedMaterialPercent = 50;
const double _kRecommendedMaterialSnap = 2;

class UiSettingsPage extends ConsumerWidget {
  const UiSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(appSettingsProvider);

    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const MoeAppBar(title: '通用设置', showBackButton: true),
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

    return MoeSettingsContent(
      child: Builder(
        builder: (context) => ListView(
          padding: moeUnderBarPadding(
            context,
            MoeSettingsLayout.verticalListPadding,
          ),
          children: [
            // ========== 聊天界面：字体、缩放、新会话默认与样式细节 ==========
            MoeSettingsGroup(
              children: [
                MoeSettingsRow(
                  key: const ValueKey('chat_ui_settings_entry'),
                  label: '聊天界面',
                  onTap: () => Navigator.of(context).push(
                    ParallaxSlidePageRoute(page: const ChatUiSettingsPage()),
                  ),
                ),
              ],
            ),

            // ========== 外观：主题色 / 壁纸 / 深色模式 ==========
            MoeSettingsGroup(
              title: '外观',
              children: [
                _buildSkinPicker(context, ref, settings, colors),
                _divider(colors),
                _buildWallpaperPicker(context, ref, settings, colors),
                _divider(colors),
                MoeSettingsRow(
                  label: '深色模式',
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
                  label: '跟随系统',
                  trailingType: MoeSettingsRowTrailing.switchControl,
                  switchValue: settings.useSystemTheme,
                  onSwitchChanged: (value) {
                    ref
                        .read(appSettingsProvider.notifier)
                        .setUseSystemTheme(value);
                  },
                ),
              ],
            ),

            // ========== 材质等级 ==========
            MoeSettingsGroup(
              title: '材质等级',
              children: [_buildMaterialPicker(context, ref, settings, colors)],
            ),

            // ========== 窗口：仅 Windows ==========
            if (_isWindowsDesktop)
              MoeSettingsGroup(
                title: '窗口',
                children: [
                  _buildWindowControlsSidePicker(
                    context,
                    ref,
                    settings,
                    colors,
                  ),
                  _divider(colors),
                  _buildWindowsCloseBehaviorPicker(ref, settings, colors),
                ],
              ),

            // ========== 高级 ==========
            MoeSettingsGroup(
              title: '高级',
              children: [
                MoeSettingsRow(
                  label: '恢复默认界面设置',
                  trailingType: MoeSettingsRowTrailing.none,
                  onTap: () => _confirmResetInterface(context, ref),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmResetInterface(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final confirmed = await showMeoTalkConfirm(
      context: context,
      title: '恢复默认界面设置',
      message:
          '深浅色、材质、主题色、全局壁纸、缩放、聊天样式、分段和思维链显示会回到新装时的样子。\n'
          '聊天记录、角色、各聊天自己设的样式和壁纸、模型和渠道、你的资料、导入过的壁纸都会保留。',
      cancelText: '取消',
      confirmText: '恢复',
    );
    if (confirmed != true) return;
    try {
      await ref.read(appSettingsProvider.notifier).resetInterfaceSettings();
      if (context.mounted) MoeToast.success(context, '已恢复默认界面设置');
    } catch (_) {
      if (context.mounted) MoeToast.error(context, '没能恢复，请重试');
    }
  }

  /// 分组内自定义块之间的分割线，与 MoeSettingsRow 的行间分割线一致。
  Widget _divider(MoeColors colors) =>
      Divider(height: 0.5, thickness: 0.5, color: colors.divider);

  /// 分组内自定义块的标题（与设置行标题一致）。
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

  /// 主题色选择块：内置配色加末尾「自定义」，一行三格与下方壁纸格同宽；
  /// 点「自定义」切过去并进入调色页。
  Widget _buildSkinPicker(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
    MoeColors colors,
  ) {
    final current = settings.interfaceSkin;
    final notifier = ref.read(appSettingsProvider.notifier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _blockLabel(colors, '主题色'),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final skin in InterfaceSkin.values)
                Expanded(
                  child: _buildSkinTile(
                    settings,
                    colors,
                    skin,
                    isSelected: skin == current,
                    onTap: skin == InterfaceSkin.custom
                        ? () {
                            if (current != skin)
                              notifier.setInterfaceSkin(skin);
                            Navigator.of(context).push(
                              ParallaxSlidePageRoute(
                                page: const CustomSkinPage(),
                              ),
                            );
                          }
                        : skin == current
                        ? null
                        : () => notifier.setInterfaceSkin(skin),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSkinTile(
    AppSettings settings,
    MoeColors colors,
    InterfaceSkin skin, {
    required bool isSelected,
    required VoidCallback? onTap,
  }) {
    final resolved = settings.copyWith(interfaceSkin: skin);
    const lightBg = moeSurface;
    final borderWidth = isSelected ? 2.0 : 1.0;
    return GestureDetector(
      key: ValueKey('interface-skin-${skin.value}'),
      onTap: onTap,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Container(
              height: 44,
              padding: EdgeInsets.all(borderWidth),
              decoration: MoeG2Decoration(
                radius: 12,
                color: isSelected ? colors.accentColor : colors.borderLight,
              ),
              // 左半浅色、右半暗色，各放一枚对应强调色圆点
              child: MoeG2ClipRRect(
                radius: 12 - borderWidth,
                child: Row(
                  children: [
                    Expanded(
                      child: ColoredBox(
                        color: lightBg,
                        child: Center(
                          child: _skinDot(
                            resolved.lightAccentColor,
                            isSelected,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: ColoredBox(
                        color: moeSurfaceDark,
                        child: Center(
                          child: _skinDot(resolved.darkAccentColor, isSelected),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                skin.label,
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

  /// 全局壁纸：内置、用户添加的自定义壁纸，末尾一格「＋」添加新图。
  /// 点未选中的格切换过去，再点已选中的格进入编辑页调遮罩与模糊。
  Widget _buildWallpaperPicker(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
    MoeColors colors,
  ) {
    final notifier = ref.read(appSettingsProvider.notifier);
    final brightness = Theme.of(context).brightness;
    final activeCustom = settings.activeCustomWallpaper;
    final customs = settings.globalWallpaperCustoms;
    void edit(GlobalWallpaper wallpaper, [CustomWallpaper? custom]) =>
        Navigator.of(context).push(
          ParallaxSlidePageRoute(
            page: GlobalWallpaperEditPage(wallpaper: wallpaper, custom: custom),
          ),
        );
    final tiles = <Widget>[
      for (final wallpaper in GlobalWallpaper.values)
        if (wallpaper != GlobalWallpaper.custom)
          _buildWallpaperTile(
            colors,
            key: 'global-wallpaper-${wallpaper.value}',
            label: wallpaper.label,
            preview: _wallpaperPreview(
              wallpaper.assetFor(GlobalWallpaperSlot.empty, brightness),
            ),
            alignment: wallpaper.alignment,
            isSelected:
                activeCustom == null && settings.globalWallpaper == wallpaper,
            editable: wallpaper != GlobalWallpaper.none,
            onSelect: () => notifier.setGlobalWallpaper(wallpaper),
            onEdit: () => edit(wallpaper),
          ),
      for (final (index, custom) in customs.indexed)
        _buildWallpaperTile(
          colors,
          key: 'global-wallpaper-custom-${custom.id}',
          label: customs.length == 1 ? '自定义' : '自定义 ${index + 1}',
          preview: _wallpaperPreview(custom.imagePath, isFile: true),
          isSelected: activeCustom?.id == custom.id,
          editable: true,
          onSelect: () => notifier.selectCustomGlobalWallpaper(custom.id),
          onEdit: () => edit(GlobalWallpaper.custom, custom),
        ),
      _buildWallpaperTile(
        colors,
        key: 'global-wallpaper-add',
        label: '添加',
        isSelected: false,
        editable: false,
        placeholderIcon: Icons.add_rounded,
        onSelect: () => _addCustomWallpaper(context, ref),
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _blockLabel(colors, '全局壁纸'),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth / 3;
              return Wrap(
                runSpacing: 10,
                children: [
                  for (final tile in tiles) SizedBox(width: width, child: tile),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  ImageProvider? _wallpaperPreview(String? source, {bool isFile = false}) {
    final path = source?.trim();
    if (path == null || path.isEmpty) return null;
    final ImageProvider image = isFile
        ? FileImage(File(path))
        : AssetImage(path);
    return ResizeImage(image, width: 240);
  }

  Future<void> _addCustomWallpaper(BuildContext context, WidgetRef ref) async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    final file = picked?.files.firstOrNull;
    final bytes = file?.bytes;
    if (file == null || bytes == null || bytes.isEmpty || !context.mounted) {
      return;
    }
    await ref
        .read(appSettingsProvider.notifier)
        .addCustomGlobalWallpaper(bytes, file.name);
  }

  Widget _buildWallpaperTile(
    MoeColors colors, {
    required String key,
    required String label,
    required bool isSelected,
    required bool editable,
    required VoidCallback onSelect,
    VoidCallback? onEdit,
    ImageProvider? preview,
    Alignment alignment = Alignment.center,
    IconData placeholderIcon = Icons.block_rounded,
  }) {
    final borderWidth = isSelected ? 2.0 : 1.0;
    return GestureDetector(
      key: ValueKey(key),
      onTap: !isSelected ? onSelect : (editable ? onEdit : null),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Container(
              height: 64,
              padding: EdgeInsets.all(borderWidth),
              decoration: MoeG2Decoration(
                radius: 12,
                color: isSelected ? colors.accentColor : colors.borderLight,
              ),
              child: MoeG2ClipRRect(
                radius: 12 - borderWidth,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (preview == null)
                      MoeInsetSurface(
                        child: Icon(
                          placeholderIcon,
                          size: 18,
                          color: colors.textSecondary,
                        ),
                      )
                    else
                      Image(
                        image: preview,
                        fit: BoxFit.cover,
                        alignment: alignment,
                        errorBuilder: (_, __, ___) => const MoeInsetSurface(),
                      ),
                    // 选中且可编辑时角上提示「再点一下进入调节」。
                    if (isSelected && editable)
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: colors.accentColor,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.tune_rounded,
                            size: 12,
                            color: Colors.white,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: isSelected
                  ? MoeFontWeights.emphasis
                  : MoeFontWeights.normal,
              color: isSelected ? colors.text : colors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _skinDot(Color color, bool isSelected) {
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: isSelected
          ? Icon(
              Icons.check_rounded,
              size: 12,
              color: color.computeLuminance() > 0.55
                  ? Colors.black87
                  : Colors.white,
            )
          : null,
    );
  }

  /// 材质等级三选一（纯色／模糊／玻璃）+ 模糊度、底色填充两条独立滑块；
  /// 两条滑块的 50% 为推荐档，即最接近 iOS 的参数。
  Widget _buildMaterialPicker(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
    MoeColors colors,
  ) {
    final material = settings.surfaceMaterial;
    final isFrosted = material == MoeSurfaceMaterial.frosted;
    final notifier = ref.read(appSettingsProvider.notifier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MoeSegmentedControl<MoeSurfaceMaterial>(
            value: material,
            segments: [
              for (final material in MoeSurfaceMaterial.values)
                MoeSegment(value: material, label: material.label),
            ],
            onChanged: (material) =>
                _setSurfaceMaterial(context, ref, material),
          ),
          if (material == MoeSurfaceMaterial.liquid) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 15,
                    color: colors.toastWarning,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '此项极耗费性能，容易引起发热和卡顿。手机端日用推荐模糊或纯色。',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.toastWarning,
                        fontWeight: MoeFontWeights.emphasis,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (material != MoeSurfaceMaterial.solid) ...[
            const SizedBox(height: 8),
            // Frosted and glass each keep their own blur and fill.
            _MaterialSlider(
              key: ValueKey('material-blur-slider-${material.name}'),
              sliderKey: const ValueKey('material-blur-slider'),
              colors: colors,
              label: '模糊度',
              percent:
                  (isFrosted
                      ? settings.frostedBlurSigma
                      : settings.glassBlurSigma) /
                  kMaxGlassBlurSigma *
                  100,
              onChanged: (value) {
                final sigma = value / 100 * kMaxGlassBlurSigma;
                return isFrosted
                    ? notifier.setFrostedBlurSigma(sigma)
                    : notifier.setGlassBlurSigma(sigma);
              },
            ),
            _MaterialSlider(
              key: ValueKey('material-tint-slider-${material.name}'),
              sliderKey: const ValueKey('material-tint-slider'),
              colors: colors,
              label: '底色填充',
              percent:
                  (isFrosted
                      ? settings.frostedTintFill
                      : settings.glassTintFill) *
                  100,
              onChanged: (value) => isFrosted
                  ? notifier.setFrostedTintFill(value / 100)
                  : notifier.setGlassTintFill(value / 100),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _setSurfaceMaterial(
    BuildContext context,
    WidgetRef ref,
    MoeSurfaceMaterial material,
  ) async {
    try {
      await ref.read(appSettingsProvider.notifier).setSurfaceMaterial(material);
    } catch (_) {
      if (context.mounted) {
        MoeToast.error(context, '材质设置未保存，请重试');
      }
    }
  }

  /// Windows 窗口按钮位置（仿 Mac 三点）
  Widget _buildWindowControlsSidePicker(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
    MoeColors colors,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _blockLabel(colors, '窗口按钮位置'),
          const SizedBox(height: 10),
          MoeSegmentedControl<WindowControlButtonSide>(
            value: settings.windowsWindowControlsSide,
            segments: const [
              MoeSegment(value: WindowControlButtonSide.left, label: '左'),
              MoeSegment(value: WindowControlButtonSide.right, label: '右'),
            ],
            onChanged: (side) => ref
                .read(appSettingsProvider.notifier)
                .setWindowsWindowControlsSide(side),
          ),
        ],
      ),
    );
  }

  /// Windows 关闭窗口时退出还是留在托盘
  Widget _buildWindowsCloseBehaviorPicker(
    WidgetRef ref,
    AppSettings settings,
    MoeColors colors,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _blockLabel(colors, '关闭窗口时'),
          const SizedBox(height: 2),
          Text(
            '收进托盘后主动消息和来电照常进行，完全退出则会停止',
            style: TextStyle(fontSize: 13, color: colors.muted),
          ),
          const SizedBox(height: 10),
          MoeSegmentedControl<WindowsCloseBehavior>(
            value: settings.windowsCloseBehavior,
            segments: [
              for (final behavior in WindowsCloseBehavior.values)
                MoeSegment(value: behavior, label: behavior.label),
            ],
            onChanged: (behavior) => ref
                .read(appSettingsProvider.notifier)
                .setWindowsCloseBehavior(behavior),
          ),
        ],
      ),
    );
  }
}

/// 材质滑块：拖动时滑块位置只走本地状态，立即跟手；保存串行进行，
/// 只写最新值，避免每帧等一次落库再刷新整个应用。
class _MaterialSlider extends StatefulWidget {
  const _MaterialSlider({
    super.key,
    required this.sliderKey,
    required this.colors,
    required this.label,
    required this.percent,
    required this.onChanged,
  });

  final Key sliderKey;
  final MoeColors colors;
  final String label;
  final double percent;
  final Future<void> Function(double percent) onChanged;

  @override
  State<_MaterialSlider> createState() => _MaterialSliderState();
}

class _MaterialSliderState extends State<_MaterialSlider> {
  double? _dragValue;
  double? _pending;
  bool _saving = false;

  Future<void> _save(double value) async {
    _pending = value;
    if (_saving) return;
    _saving = true;
    try {
      while (_pending != null) {
        final next = _pending!;
        _pending = null;
        await widget.onChanged(next);
      }
    } catch (_) {
      _pending = null;
      if (mounted) MoeToast.error(context, '${widget.label}未保存，请重试');
    } finally {
      _saving = false;
      // Release the local value once the saved setting has caught up.
      if (mounted && _pending == null) setState(() => _dragValue = null);
    }
  }

  double _snap(double v) =>
      (v - _kRecommendedMaterialPercent).abs() < _kRecommendedMaterialSnap
      ? _kRecommendedMaterialPercent.toDouble()
      : v;

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final value = (_dragValue ?? widget.percent).clamp(0.0, 100.0).toDouble();
    final isRecommended = value.round() == _kRecommendedMaterialPercent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(fontSize: 13, color: colors.textSecondary),
                ),
              ),
              Text(
                isRecommended ? '${value.round()}% · 推荐' : '${value.round()}%',
                style: TextStyle(
                  fontSize: 13,
                  color: colors.accentColor,
                  fontWeight: MoeFontWeights.emphasis,
                ),
              ),
            ],
          ),
        ),
        MoeSlider(
          key: widget.sliderKey,
          value: value,
          min: 0,
          max: 100,
          label: '${value.round()}%',
          semanticFormatterCallback: (v) => '${widget.label} ${v.round()}%',
          onChanged: (v) {
            // Snap onto the recommended iOS-like midpoint so it is easy to hit.
            final snapped = _snap(v);
            setState(() => _dragValue = snapped);
            _save(snapped);
          },
        ),
      ],
    );
  }
}

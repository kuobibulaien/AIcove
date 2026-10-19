import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../core/utils/message_formatter.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
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
    final chunkConfig = settings.messageFormatConfig;
    final activeSet =
        chunkConfig.activeChunkPunctuationSet ??
        (chunkConfig.chunkPunctuationSets.isNotEmpty
            ? chunkConfig.chunkPunctuationSets.first
            : null);
    final activeSetName = activeSet == null
        ? null
        : _displaySetName(
            activeSet,
            chunkConfig.chunkPunctuationSets.indexWhere(
              (item) => item.id == activeSet.id,
            ),
          );

    return MoeSettingsContent(
      child: Builder(
        builder: (context) => ListView(
          padding: moeUnderBarPadding(
            context,
            MoeSettingsLayout.verticalListPadding,
          ),
          children: [
            // ========== 外观：界面皮肤 / 深色模式 ==========
            MoeSettingsGroup(
              title: '外观',
              children: [
                _buildSkinPicker(ref, settings, colors),
                _divider(colors),
                _buildWallpaperPicker(context, ref, settings, colors),
                _divider(colors),
                MoeSettingsRow(
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

            // ========== 显示：字体 / 缩放 / 窗口按钮 ==========
            MoeSettingsGroup(
              title: '显示',
              children: [
                _buildScaleSlider(
                  colors: colors,
                  label: '字体大小',
                  value: settings.textScaleFactor.clamp(
                    kMinTextScaleFactor,
                    kMaxTextScaleFactor,
                  ),
                  min: kMinTextScaleFactor,
                  max: kMaxTextScaleFactor,
                  divisions: 8, // 0.05 步长：(1.2-0.8)/0.05 = 8
                  onChanged: (value) => ref
                      .read(appSettingsProvider.notifier)
                      .setTextScaleFactor(value),
                  onValueTap: () => _showScaleInputDialog(
                    context,
                    title: '输入字体缩放值',
                    hint: '范围 $kMinTextScaleFactor ~ $kMaxTextScaleFactor',
                    min: kMinTextScaleFactor,
                    max: kMaxTextScaleFactor,
                    current: settings.textScaleFactor.clamp(
                      kMinTextScaleFactor,
                      kMaxTextScaleFactor,
                    ),
                    onSave: (value) => ref
                        .read(appSettingsProvider.notifier)
                        .setTextScaleFactor(value),
                  ),
                ),
                _divider(colors),
                _buildScaleSlider(
                  colors: colors,
                  label: '界面缩放',
                  value: settings.uiScaleFactor.clamp(
                    kMinUiScaleFactor,
                    kMaxUiScaleFactor,
                  ),
                  min: kMinUiScaleFactor,
                  max: kMaxUiScaleFactor,
                  divisions: 6, // 0.05 步长：(1.15-0.85)/0.05 = 6
                  onChanged: (value) => ref
                      .read(appSettingsProvider.notifier)
                      .setUiScaleFactor(value),
                  onValueTap: () => _showScaleInputDialog(
                    context,
                    title: '输入界面缩放值',
                    hint: '范围 $kMinUiScaleFactor ~ $kMaxUiScaleFactor',
                    min: kMinUiScaleFactor,
                    max: kMaxUiScaleFactor,
                    current: settings.uiScaleFactor.clamp(
                      kMinUiScaleFactor,
                      kMaxUiScaleFactor,
                    ),
                    onSave: (value) => ref
                        .read(appSettingsProvider.notifier)
                        .setUiScaleFactor(value),
                  ),
                ),
                if (_isWindowsDesktop) ...[
                  _divider(colors),
                  _buildWindowControlsSidePicker(
                    context,
                    ref,
                    settings,
                    colors,
                  ),
                  _divider(colors),
                  _buildWindowsCloseBehaviorPicker(ref, settings, colors),
                ],
              ],
            ),

            // ========== 聊天：图片预览 / 气泡 ==========
            MoeSettingsGroup(
              title: '聊天',
              children: [
                _buildScaleSlider(
                  colors: colors,
                  label: '图片预览大小',
                  value: settings.imagePreviewScale.clamp(
                    kMinImagePreviewScale,
                    kMaxImagePreviewScale,
                  ),
                  min: kMinImagePreviewScale,
                  max: kMaxImagePreviewScale,
                  divisions: 20, // 0.05 步长：(1.5-0.5)/0.05 = 20
                  onChanged: (value) => ref
                      .read(appSettingsProvider.notifier)
                      .setImagePreviewScale(value),
                  onValueTap: () => _showScaleInputDialog(
                    context,
                    title: '输入图片预览缩放值',
                    hint: '范围 $kMinImagePreviewScale ~ $kMaxImagePreviewScale',
                    min: kMinImagePreviewScale,
                    max: kMaxImagePreviewScale,
                    current: settings.imagePreviewScale.clamp(
                      kMinImagePreviewScale,
                      kMaxImagePreviewScale,
                    ),
                    onSave: (value) => ref
                        .read(appSettingsProvider.notifier)
                        .setImagePreviewScale(value),
                  ),
                ),
                _divider(colors),
                MoeSettingsRow(
                  label: '语音消息气泡',
                  subtitle: settings.expandAudioText ? '默认展开文字' : '收回文字',
                  trailingType: MoeSettingsRowTrailing.switchControl,
                  switchValue: settings.expandAudioText,
                  onSwitchChanged: (value) {
                    ref
                        .read(appSettingsProvider.notifier)
                        .setExpandAudioText(value);
                  },
                ),
                MoeSettingsRow(
                  label: '隐藏用户头像',
                  trailingType: MoeSettingsRowTrailing.switchControl,
                  switchValue: settings.hideUserAvatar,
                  onSwitchChanged: (value) {
                    ref
                        .read(appSettingsProvider.notifier)
                        .setHideUserAvatar(value);
                  },
                ),
              ],
            ),

            // ========== 聊天样式与消息分段 ==========
            MoeSettingsGroup(
              title: '聊天样式与分段',
              children: [
                MoeSettingsRow(
                  label: '新会话默认样式',
                  subtitle: '可在单个聊天的菜单里单独切换',
                  trailingType: MoeSettingsRowTrailing.custom,
                  trailing: MoeSegmentedControl<ChatDisplayStyle>(
                    key: const ValueKey('chat_display_style_toggle'),
                    expanded: false,
                    value: settings.chatDisplayStyle,
                    segments: const [
                      MoeSegment(
                        value: ChatDisplayStyle.bubble,
                        label: '气泡',
                      ),
                      MoeSegment(
                        value: ChatDisplayStyle.document,
                        label: '文档',
                      ),
                    ],
                    onChanged: (style) => ref
                        .read(appSettingsProvider.notifier)
                        .setChatDisplayStyle(style),
                  ),
                ),
                MoeSettingsRow(
                  label: '启用消息分段',
                  subtitle: '长回复拆成多条气泡发送',
                  trailingType: MoeSettingsRowTrailing.switchControl,
                  switchValue: chunkConfig.enableChunking,
                  onSwitchChanged: (value) async {
                    await ref
                        .read(appSettingsProvider.notifier)
                        .updateMessageFormatConfig(
                          chunkConfig.copyWith(enableChunking: value),
                        );
                  },
                ),
                MoeSettingsRow(
                  label: '过滤句末标点',
                  trailingType: MoeSettingsRowTrailing.switchControl,
                  switchValue: chunkConfig.filterPunctuation,
                  onSwitchChanged: (value) async {
                    await ref
                        .read(appSettingsProvider.notifier)
                        .updateMessageFormatConfig(
                          chunkConfig.copyWith(filterPunctuation: value),
                        );
                  },
                ),
                if (chunkConfig.enableChunking)
                  MoeSettingsRow(
                    label: '分段标点',
                    trailingType: MoeSettingsRowTrailing.text,
                    detailText: activeSetName ?? '',
                    onTap: () => _showPunctuationSheet(context),
                  ),
              ],
            ),

            // ========== 高级：自定义皮肤（刻意放在页底） ==========
            MoeSettingsGroup(
              title: '高级',
              children: [
                MoeSettingsRow(
                  label: '自定义皮肤',
                  onTap: () => Navigator.of(
                    context,
                  ).push(ParallaxSlidePageRoute(page: const CustomSkinPage())),
                ),
              ],
            ),
          ],
        ),
      ),
    );
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

  /// 界面皮肤选择块：内置皮肤；当前为自定义皮肤时额外显示自定义格。
  Widget _buildSkinPicker(
    WidgetRef ref,
    AppSettings settings,
    MoeColors colors,
  ) {
    final current = settings.interfaceSkin;
    final options = [
      ...InterfaceSkin.presets,
      if (current == InterfaceSkin.custom) InterfaceSkin.custom,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _blockLabel(colors, '界面皮肤'),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final skin in options)
                Expanded(
                  child: _buildSkinTile(
                    ref,
                    settings,
                    colors,
                    skin,
                    isSelected: skin == current,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSkinTile(
    WidgetRef ref,
    AppSettings settings,
    MoeColors colors,
    InterfaceSkin skin, {
    required bool isSelected,
  }) {
    final resolved = settings.copyWith(interfaceSkin: skin);
    final lightBg = resolved.lightChatBackground ?? moeSurface;
    final borderWidth = isSelected ? 2.0 : 1.0;
    return GestureDetector(
      onTap: isSelected
          ? null
          : () => ref.read(appSettingsProvider.notifier).setInterfaceSkin(skin),
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
                      ColoredBox(
                        color: colors.surface,
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
                        errorBuilder: (_, __, ___) =>
                            ColoredBox(color: colors.surface),
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

  /// 数值滑块块：标题 + 可点击数值 + 滑块 + 可选说明
  Widget _buildScaleSlider({
    required MoeColors colors,
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
    required VoidCallback onValueTap,
    String? note,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: _blockLabel(colors, label)),
              GestureDetector(
                onTap: onValueTap,
                child: MoeButtonSurface(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  radius: 6,
                  tintColor: colors.accentColor.withValues(alpha: 0.15),
                  child: Text(
                    value.toStringAsFixed(2),
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
          MoeSlider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
          if (note != null)
            Text(note, style: TextStyle(fontSize: 12, color: colors.muted)),
        ],
      ),
    );
  }

  /// 弹窗手动输入缩放值
  void _showScaleInputDialog(
    BuildContext context, {
    required String title,
    required String hint,
    required double min,
    required double max,
    required double current,
    required Future<void> Function(double) onSave,
  }) {
    showMoeAutoSaveTextEditor(
      context: context,
      title: title,
      initialValue: current.toStringAsFixed(2),
      hint: hint,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onSave: (text) async {
        final value = double.tryParse(text);
        if (value == null || !value.isFinite || value < min || value > max) {
          throw const FormatException('请输入范围内的数值');
        }
        await onSave(value);
      },
    );
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
          const SizedBox(height: 2),
          Text(
            '窗口关闭、最小化、最大化按钮所在侧',
            style: TextStyle(fontSize: 13, color: colors.muted),
          ),
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

  /// 分段标点管理弹层
  void _showPunctuationSheet(BuildContext context) {
    showMoeBottomSheet<void>(
      context: context,
      title: '分段标点',
      showCloseButton: true,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final settings = ref.watch(appSettingsProvider).valueOrNull;
          final colors = context.moeColors;
          if (settings == null) {
            return const SizedBox(
              height: 200,
              child: Center(child: MoeLoadingIndicator()),
            );
          }
          return _buildPunctuationSheetBody(context, ref, settings, colors);
        },
      ),
    );
  }

  Widget _buildPunctuationSheetBody(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
    MoeColors colors,
  ) {
    final config = settings.messageFormatConfig;
    final sets = config.chunkPunctuationSets;
    final activeSet =
        config.activeChunkPunctuationSet ??
        (sets.isNotEmpty
            ? sets.first
            : const MessageChunkPunctuationSet(
                id: 'conservative',
                name: '保守',
                punctuations: <String>[],
              ));

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '标点集合',
            style: TextStyle(
              fontSize: 13,
              fontWeight: MoeFontWeights.emphasis,
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < sets.length; i++)
            _buildPunctuationSetRow(
              context,
              ref,
              settings,
              colors,
              sets,
              sets[i],
              i,
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: IntrinsicWidth(
              child: MoeSecondaryButton(
                label: '另存为集合',
                icon: Icons.save_outlined,
                size: MoeSecondaryButtonSize.sm,
                onPressed: () =>
                    _showSaveAsSetDialog(context, ref, settings, activeSet),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '当前标点',
            style: TextStyle(
              fontSize: 13,
              fontWeight: MoeFontWeights.emphasis,
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < activeSet.punctuations.length; i++)
                InputChip(
                  label: Text(activeSet.punctuations[i]),
                  onPressed: () => _editPunctuationToken(
                    context,
                    ref,
                    settings,
                    activeSet,
                    i,
                  ),
                  onDeleted: () => _deletePunctuationToken(
                    context,
                    ref,
                    settings,
                    activeSet,
                    i,
                  ),
                  deleteIconColor: colors.muted,
                ),
              ActionChip(
                avatar: const Icon(Icons.add, size: 16),
                label: const Text('新增标点'),
                onPressed: () =>
                    _addPunctuationToken(context, ref, settings, activeSet),
              ),
            ],
          ),
          if (activeSet.punctuations.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '当前集合为空：只在换行或超过3个连续空格时分段',
                style: TextStyle(fontSize: 13, color: colors.muted),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPunctuationSetRow(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
    MoeColors colors,
    List<MessageChunkPunctuationSet> sets,
    MessageChunkPunctuationSet set,
    int index,
  ) {
    final selected =
        settings.messageFormatConfig.activeChunkPunctuationSetId == set.id;
    final label = _displaySetName(set, index);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: () =>
            _updateChunkPunctuationSets(context, ref, settings, sets, set.id),
        child: Container(
          decoration: MoeG2Decoration(
            radius: 12,
            color: selected
                ? colors.accentColor.withValues(alpha: 0.10)
                : colors.surfaceAlt,
            border: Border.all(
              color: selected ? colors.accentColor : colors.borderLight,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 0, 10),
                  child: Row(
                    children: [
                      if (selected) ...[
                        Icon(
                          Icons.check_rounded,
                          size: 16,
                          color: colors.accentColor,
                        ),
                        const SizedBox(width: 6),
                      ],
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: selected
                                ? MoeFontWeights.emphasis
                                : MoeFontWeights.normal,
                            color: colors.text,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              MoeIconButton(
                icon: Icons.edit_outlined,
                size: 18,
                padding: const EdgeInsets.all(6),
                minTouchTarget: 32,
                color: colors.muted,
                tooltip: '重命名',
                onTap: () =>
                    _showRenameSetDialog(context, ref, settings, set, index),
              ),
              MoeIconButton(
                icon: Icons.delete_outline,
                size: 18,
                padding: const EdgeInsets.all(6),
                minTouchTarget: 32,
                color: colors.muted,
                tooltip: '删除集合',
                enabled: sets.length > 1,
                onTap: sets.length <= 1
                    ? null
                    : () => _deleteSet(context, ref, settings, set.id),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _displaySetName(MessageChunkPunctuationSet set, int index) {
    final name = set.name?.trim() ?? '';
    if (name.isNotEmpty) return name;
    final safeIndex = index < 0 ? 0 : index;
    return '未命名集合${safeIndex + 1}';
  }

  String _createSetId() => 'set_${DateTime.now().microsecondsSinceEpoch}';

  Future<void> _updateChunkPunctuationSets(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
    List<MessageChunkPunctuationSet> sets,
    String activeSetId, {
    String? successText,
  }) async {
    if (sets.isEmpty) return;
    final activeSet = sets.firstWhere(
      (item) => item.id == activeSetId,
      orElse: () => sets.first,
    );
    final newConfig = settings.messageFormatConfig.copyWith(
      chunkPunctuationSets: sets,
      activeChunkPunctuationSetId: activeSet.id,
      chunkPunctuations: activeSet.punctuations,
    );
    await ref
        .read(appSettingsProvider.notifier)
        .updateMessageFormatConfig(newConfig);
    if (successText != null && context.mounted) {
      MoeToast.success(context, successText);
    }
  }

  Future<void> _showSaveAsSetDialog(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
    MessageChunkPunctuationSet source,
  ) async {
    final controller = TextEditingController();
    final confirmed = await showMeoTalkDialog(
      context: context,
      title: '保存为新集合',
      cancelText: '取消',
      confirmText: '添加',
      content: MoeTextField(
        controller: controller,
        hint: '可选名称，留空则未命名',
      ),
    );
    final name = controller.text.trim();
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (confirmed != true || !context.mounted) return;
    final newSet = MessageChunkPunctuationSet(
      id: _createSetId(),
      name: name.isEmpty ? null : name,
      punctuations: List<String>.from(source.punctuations),
    );
    final nextSets = <MessageChunkPunctuationSet>[
      ...settings.messageFormatConfig.chunkPunctuationSets,
      newSet,
    ];
    await _updateChunkPunctuationSets(
      context,
      ref,
      settings,
      nextSets,
      newSet.id,
      successText: '已保存新集合',
    );
  }

  Future<void> _showRenameSetDialog(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
    MessageChunkPunctuationSet target,
    int index,
  ) async {
    await showMoeAutoSaveTextEditor(
      context: context,
      title: '重命名集合',
      initialValue: target.name ?? '',
      onSave: (text) async {
        final current = ref.read(appSettingsProvider).requireValue;
        final sets = [...current.messageFormatConfig.chunkPunctuationSets];
        final i = sets.indexWhere((set) => set.id == target.id);
        if (i < 0) throw const FormatException('此集合已不存在');
        sets[i] = sets[i].copyWith(
          name: text.trim().isEmpty ? null : text.trim(),
        );
        await ref
            .read(appSettingsProvider.notifier)
            .updateMessageFormatConfig(
              current.messageFormatConfig.copyWith(chunkPunctuationSets: sets),
            );
      },
    );
  }

  Future<String?> _showPunctuationInputDialog(
    BuildContext context, {
    required String title,
    String initialValue = '',
  }) async {
    final controller = TextEditingController(text: initialValue);
    final confirmed = await showMeoTalkDialog(
      context: context,
      title: title,
      cancelText: '取消',
      confirmText: '添加',
      content: MoeTextField(
        controller: controller,
        hint: '输入一个标点或组合',
        autofocus: true,
      ),
    );
    final value = controller.text.trim();
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (confirmed != true || value.isEmpty) return null;
    return value;
  }

  Future<void> _addPunctuationToken(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
    MessageChunkPunctuationSet activeSet,
  ) async {
    final token = await _showPunctuationInputDialog(context, title: '新增标点');
    if (!context.mounted) return;
    if (token == null) return;
    if (activeSet.punctuations.contains(token)) {
      if (context.mounted) {
        MoeToast.warning(context, '该标点已存在');
      }
      return;
    }

    final sets = List<MessageChunkPunctuationSet>.from(
      settings.messageFormatConfig.chunkPunctuationSets,
    );
    final index = sets.indexWhere((item) => item.id == activeSet.id);
    if (index < 0) return;

    final nextPunctuations = <String>[...sets[index].punctuations, token];
    sets[index] = sets[index].copyWith(punctuations: nextPunctuations);
    await _updateChunkPunctuationSets(
      context,
      ref,
      settings,
      sets,
      activeSet.id,
      successText: '标点已添加',
    );
  }

  Future<void> _editPunctuationToken(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
    MessageChunkPunctuationSet activeSet,
    int tokenIndex,
  ) async {
    await showMoeAutoSaveTextEditor(
      context: context,
      title: '编辑标点',
      initialValue: activeSet.punctuations[tokenIndex],
      onSave: (text) async {
        final token = text.trim();
        if (token.isEmpty) throw const FormatException('标点不能为空');
        final current = ref.read(appSettingsProvider).requireValue;
        final sets = [...current.messageFormatConfig.chunkPunctuationSets];
        final i = sets.indexWhere((set) => set.id == activeSet.id);
        if (i < 0 || tokenIndex >= sets[i].punctuations.length) {
          throw const FormatException('此标点已不存在');
        }
        final tokens = [...sets[i].punctuations];
        if (tokens.asMap().entries.any(
          (entry) => entry.key != tokenIndex && entry.value == token,
        )) {
          throw const FormatException('该标点已存在');
        }
        tokens[tokenIndex] = token;
        sets[i] = sets[i].copyWith(punctuations: tokens);
        await ref
            .read(appSettingsProvider.notifier)
            .updateMessageFormatConfig(
              current.messageFormatConfig.copyWith(chunkPunctuationSets: sets),
            );
      },
    );
  }

  Future<void> _deletePunctuationToken(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
    MessageChunkPunctuationSet activeSet,
    int tokenIndex,
  ) async {
    final sets = List<MessageChunkPunctuationSet>.from(
      settings.messageFormatConfig.chunkPunctuationSets,
    );
    final index = sets.indexWhere((item) => item.id == activeSet.id);
    if (index < 0) return;
    final nextPunctuations = List<String>.from(sets[index].punctuations)
      ..removeAt(tokenIndex);
    sets[index] = sets[index].copyWith(punctuations: nextPunctuations);
    await _updateChunkPunctuationSets(
      context,
      ref,
      settings,
      sets,
      activeSet.id,
      successText: '标点已删除',
    );
  }

  Future<void> _deleteSet(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
    String setId,
  ) async {
    final currentSets = settings.messageFormatConfig.chunkPunctuationSets;
    if (currentSets.length <= 1) {
      if (context.mounted) {
        MoeToast.warning(context, '至少保留一个集合');
      }
      return;
    }

    final nextSets = currentSets.where((item) => item.id != setId).toList();
    final currentActiveId =
        settings.messageFormatConfig.activeChunkPunctuationSetId;
    final nextActiveId = currentActiveId == setId
        ? nextSets.first.id
        : currentActiveId;
    await _updateChunkPunctuationSets(
      context,
      ref,
      settings,
      nextSets,
      nextActiveId,
      successText: '集合已删除',
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

import 'package:aicove_flutter/src/ui/theme/moe_interaction_theme.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'spring_transition_demo.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';

/// UI 组件库页面 - 用于展示所有公共组件
class UiGalleryPage extends StatefulWidget {
  const UiGalleryPage({super.key});

  @override
  State<UiGalleryPage> createState() => _UiGalleryPageState();
}

class _UiGalleryPageState extends State<UiGalleryPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _liquidAnimController;
  bool _switchValue = true;
  bool _checkboxValue = true;
  final TextEditingController _textController = TextEditingController(
    text: 'Hello MoeTalk',
  );
  double _cornerRadius = 20.0;

  bool _liquidGlassEnabled = true;
  double _liquidThickness = 20.0;
  double _liquidBlur = 8.0;
  double _liquidRefraction = 1.25;

  @override
  void initState() {
    super.initState();
    _liquidAnimController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    );
    if (!WidgetsBinding.instance.runtimeType.toString().contains('Test')) {
      _liquidAnimController.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _liquidAnimController.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return MoePageScaffold(
      backgroundColor: colors.bgMain,
      appBar: const MoeAppBar(title: '组件库 (UI Kit)', showBackButton: true),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: MoeSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader('连续打断转场'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: MoeSpacing.md),
              child: Wrap(
                spacing: MoeSpacing.sm,
                runSpacing: MoeSpacing.sm,
                children: [
                  for (final demo in SpringTransitionDemo.values)
                    MoeSecondaryButton(
                      key: ValueKey('spring-demo-${demo.name}'),
                      label: demo.label,
                      onPressed: () => openSpringTransitionDemo(context, demo),
                    ),
                ],
              ),
            ),
            const SizedBox(height: MoeSpacing.xl),

            _buildHeader('iOS 页面转场'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: MoeSpacing.md),
              child: Wrap(
                spacing: MoeSpacing.sm,
                runSpacing: MoeSpacing.sm,
                children: [
                  for (final demo in _TransitionDemo.values)
                    MoeSecondaryButton(
                      label: demo.label,
                      onPressed: () => _openTransitionDemo(context, demo),
                    ),
                ],
              ),
            ),
            const SizedBox(height: MoeSpacing.xl),

            _buildHeader('按钮组件 (Buttons)'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: MoeSpacing.md),
              child: Wrap(
                spacing: MoeSpacing.sm,
                runSpacing: MoeSpacing.sm,
                children: [
                  MoePrimaryButton(onPressed: () {}, label: '主按钮 (Primary)'),
                  MoeSecondaryButton(
                    onPressed: () {},
                    label: '次按钮 (Secondary)',
                  ),
                  MoeIconButton(icon: Icons.favorite, onTap: () {}),
                  MoeTileButton(label: '磁贴按钮', icon: Icons.star, onTap: () {}),
                ],
              ),
            ),
            const SizedBox(height: MoeSpacing.xl),

            _buildHeader('表单组件 (Form)'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: MoeSpacing.md),
              child: Column(
                children: [
                  MoeTextField(
                    controller: _textController,
                    label: '示例输入框',
                    hint: '请输入内容...',
                  ),
                  const SizedBox(height: MoeSpacing.md),
                  Wrap(
                    spacing: MoeSpacing.lg,
                    runSpacing: MoeSpacing.sm,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('开关: '),
                          MoeSwitch(
                            value: _switchValue,
                            onChanged: (v) => setState(() => _switchValue = v),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('复选框: '),
                          MoeCheckbox(
                            value: _checkboxValue,
                            onChanged: (v) =>
                                setState(() => _checkboxValue = v),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: MoeSpacing.xl),

            _buildHeader('列表组件 (List)'),
            MoeSettingsGroup(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              title: '设置分组 (Settings Group Container)',
              children: [
                MoeSettingsRow(
                  icon: Icons.settings,
                  label: '普通导航行 (Navigation Row)',
                  subtitle: '点击跳转到子页面',
                  trailingType: MoeSettingsRowTrailing.chevron,
                  onTap: () {
                    MoeToast.info(context, '点击了导航行');
                  },
                ),
                MoeSettingsRow(
                  icon: Icons.wifi_off,
                  label: '开关行 (Switch Row)',
                  subtitle: '带开关控件的设置项',
                  trailingType: MoeSettingsRowTrailing.switchControl,
                  switchValue: _switchValue,
                  onSwitchChanged: (v) {
                    setState(() => _switchValue = v);
                    MoeToast.success(context, '已${v ? "开启" : "关闭"}');
                  },
                ),
                MoeSettingsRow(
                  icon: Icons.language,
                  label: '文字详情行 (Text Detail Row)',
                  subtitle: '右侧显示当前值',
                  trailingType: MoeSettingsRowTrailing.text,
                  detailText: '简体中文',
                  onTap: () {
                    MoeToast.info(context, '点击了文字详情行');
                  },
                ),
                MoeSettingsRow(
                  icon: Icons.check_circle,
                  label: '自定义尾部 (Custom Trailing)',
                  subtitle: '可以放任意 Widget',
                  trailingType: MoeSettingsRowTrailing.custom,
                  trailing: MoeCheckbox(
                    value: _checkboxValue,
                    onChanged: (v) => setState(() => _checkboxValue = v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: MoeSpacing.md),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: MoeSpacing.md),
              child: MoeListTile(
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: MoeG2Decoration(
                    radius: 10,
                    color: colors.accentColor.withValues(alpha: 0.2),
                  ),
                  child: Icon(Icons.info_outline, color: colors.accentColor),
                ),
                title: const Text('通用列表项 (List Tile)'),
                subtitle: const Text('支持头像、标题、副标题、尾部图标'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  MoeToast.info(context, '点击了列表项');
                },
              ),
            ),
            const SizedBox(height: MoeSpacing.xl),

            _buildHeader('反馈组件 (Feedback)'),
            const Center(
              child: Column(
                children: [
                  MoeLoadingIndicator(),
                  SizedBox(height: MoeSpacing.md),
                  MoeEmptyState(
                    icon: Icons.inbox_outlined,
                    title: '空状态占位 (Empty State)',
                    description: '当列表为空或加载失败时显示',
                  ),
                ],
              ),
            ),
            const SizedBox(height: MoeSpacing.md),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: MoeSpacing.md),
              child: Wrap(
                spacing: MoeSpacing.sm,
                runSpacing: MoeSpacing.sm,
                alignment: WrapAlignment.center,
                children: [
                  MoeSecondaryButton(
                    onPressed: () {
                      MoeToast.info(context, '普通信息 (Info)');
                    },
                    label: 'Toast - Info',
                  ),
                  MoeSecondaryButton(
                    onPressed: () {
                      MoeToast.success(context, '操作成功 (Success)');
                    },
                    label: 'Toast - Success',
                  ),
                  MoeSecondaryButton(
                    onPressed: () {
                      MoeToast.error(context, '操作失败 (Error)');
                    },
                    label: 'Toast - Error',
                  ),
                  MoeSecondaryButton(
                    onPressed: () {
                      MoeToast.warning(context, '警告提示 (Warning)');
                    },
                    label: 'Toast - Warning',
                  ),
                ],
              ),
            ),
            const SizedBox(height: MoeSpacing.xl),

            _buildHeader('弹窗组件 (Sheets & Dialogs)'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: MoeSpacing.md),
              child: Wrap(
                spacing: MoeSpacing.sm,
                runSpacing: MoeSpacing.sm,
                children: [
                  MoeSecondaryButton(
                    onPressed: () {
                      showMoeActionSheet(
                        context: context,
                        actions: [
                          MoeSheetAction(label: '选项 A', onTap: () {}),
                          MoeSheetAction(label: '选项 B', onTap: () {}),
                          MoeSheetAction(
                            label: '危险操作',
                            isDestructive: true,
                            onTap: () {},
                          ),
                        ],
                      );
                    },
                    label: 'Action Sheet',
                  ),
                  MoeSecondaryButton(
                    onPressed: () {
                      showMoeBottomSheet(
                        context: context,
                        title: '选择内容',
                        builder: (context) => Container(
                          height: 200,
                          alignment: Alignment.center,
                          child: const Text('这是一个底部面板自定义内容'),
                        ),
                      );
                    },
                    label: 'Bottom Sheet',
                  ),
                  MoeSecondaryButton(
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (context) => MeoTalkDialog(
                          title: '系统提示',
                          content: const Text('确定要执行此操作吗？'),
                          confirmText: '确定',
                          onConfirm: () => Navigator.pop(context),
                        ),
                      );
                    },
                    label: 'MeoTalk Dialog',
                  ),
                ],
              ),
            ),
            const SizedBox(height: MoeSpacing.xl),

            _buildHeader('导航组件 (Navigation)'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: MoeSpacing.md),
              child: MoeFilterChipBar<String>(
                items: const [
                  MoeFilterItem(value: 'All', label: '全部'),
                  MoeFilterItem(value: 'Active', label: '进行中'),
                  MoeFilterItem(value: 'Done', label: '已完成'),
                ],
                selectedValue: 'All',
                onSelected: (val) {},
              ),
            ),
            const SizedBox(height: MoeSpacing.xl),

            _buildHeader('液态玻璃材质 (Liquid Glass Pilot)'),
            _buildLiquidGlassDemo(colors),
            const SizedBox(height: MoeSpacing.xl),

            _buildHeader('背景色对比 (Background Colors)'),
            _buildBackgroundColorsDemo(colors),
            const SizedBox(height: MoeSpacing.xl),

            _buildHeader('圆角对比 (Corner Radius)'),
            _buildCornerRadiusDemo(colors),
            const SizedBox(height: 100), // 底部留白
          ],
        ),
      ),
    );
  }

  Widget _buildLiquidGlassDemo(MoeColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MoeSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 动态移动纹理背景展示区
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              height: 220,
              width: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  AnimatedBuilder(
                    animation: _liquidAnimController,
                    builder: (context, child) {
                      final t = _liquidAnimController.value;
                      return DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment(-1.0 + t * 0.8, -1.0),
                            end: Alignment(1.0 - t * 0.8, 1.0),
                            colors: [
                              colors.primary.withValues(alpha: 0.8),
                              colors.accentColor.withValues(alpha: 0.7),
                              colors.dialogWarning.withValues(alpha: 0.6),
                              colors.primary.withValues(alpha: 0.9),
                            ],
                          ),
                        ),
                        child: CustomPaint(
                          painter: _MovingPatternPainter(animationValue: t),
                        ),
                      );
                    },
                  ),
                  Center(
                    child: MoeLiquidGlass(
                      enabled: _liquidGlassEnabled,
                      thickness: _liquidThickness,
                      blurSigma: _liquidBlur,
                      refractiveIndex: _liquidRefraction,
                      radius: 24,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        alignment: WrapAlignment.center,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.auto_awesome,
                                color: colors.accentColor,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '液态晶体胶囊',
                                    style: TextStyle(
                                      fontWeight: MoeFontWeights.emphasis,
                                      fontSize: 13,
                                      color: colors.text,
                                    ),
                                  ),
                                  Text(
                                    _liquidGlassEnabled
                                        ? 'GPU Shader 透镜折射'
                                        : '原生材质优雅降级',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: colors.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          MoeSecondaryButton(
                            label: '交互测试',
                            onPressed: () {
                              MoeToast.info(context, '晶体表面 Material 点击与水波纹正常');
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: MoeSpacing.md),

          // 控制选项
          MoeSettingsGroup(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              MoeSettingsRow(
                icon: Icons.lens_blur,
                label: '启用液态效果 (Shader)',
                subtitle: _liquidGlassEnabled ? '已开启着色器物理折射' : '已降级为原生材质',
                trailingType: MoeSettingsRowTrailing.switchControl,
                switchValue: _liquidGlassEnabled,
                onSwitchChanged: (v) => setState(() => _liquidGlassEnabled = v),
              ),
              if (_liquidGlassEnabled) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: MoeSpacing.md,
                    vertical: MoeSpacing.xs,
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 90,
                        child: Text(
                          '厚度: ${_liquidThickness.round()}px',
                          style: TextStyle(
                            fontSize: 13,
                            color: colors.text,
                            fontWeight: MoeFontWeights.emphasis,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          overlayColor: moeInteractionOverlay,
                          value: _liquidThickness,
                          min: 0,
                          max: 40,
                          divisions: 40,
                          label: '${_liquidThickness.round()}px',
                          onChanged: (v) =>
                              setState(() => _liquidThickness = v),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: MoeSpacing.md,
                    vertical: MoeSpacing.xs,
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 90,
                        child: Text(
                          '模糊: ${_liquidBlur.toStringAsFixed(1)}',
                          style: TextStyle(
                            fontSize: 13,
                            color: colors.text,
                            fontWeight: MoeFontWeights.emphasis,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          overlayColor: moeInteractionOverlay,
                          value: _liquidBlur,
                          min: 0,
                          max: 20,
                          divisions: 20,
                          label: _liquidBlur.toStringAsFixed(1),
                          onChanged: (v) => setState(() => _liquidBlur = v),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: MoeSpacing.md,
                    vertical: MoeSpacing.xs,
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 90,
                        child: Text(
                          '折射: ${_liquidRefraction.toStringAsFixed(2)}',
                          style: TextStyle(
                            fontSize: 13,
                            color: colors.text,
                            fontWeight: MoeFontWeights.emphasis,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          overlayColor: moeInteractionOverlay,
                          value: _liquidRefraction,
                          min: 1.0,
                          max: 1.5,
                          divisions: 20,
                          label: _liquidRefraction.toStringAsFixed(2),
                          onChanged: (v) =>
                              setState(() => _liquidRefraction = v),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        MoeSpacing.md,
        0,
        MoeSpacing.md,
        MoeSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: MoeFontWeights.emphasis,
              color: moePrimary,
            ),
          ),
          const SizedBox(height: 4),
          const Divider(height: 1),
        ],
      ),
    );
  }

  /// 构建圆角对比展示
  Widget _buildCornerRadiusDemo(MoeColors colors) {
    const boxSize = 100.0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MoeSpacing.md),
      child: Column(
        children: [
          // 圆角大小滑块
          Row(
            children: [
              Text(
                '圆角: ${_cornerRadius.round()}px',
                style: TextStyle(
                  fontSize: 14,
                  color: colors.text,
                  fontWeight: MoeFontWeights.emphasis,
                ),
              ),
              Expanded(
                child: Slider(
                  overlayColor: moeInteractionOverlay,
                  value: _cornerRadius,
                  min: 0,
                  max: 50,
                  divisions: 50,
                  label: '${_cornerRadius.round()}px',
                  onChanged: (v) => setState(() => _cornerRadius = v),
                ),
              ),
            ],
          ),
          const SizedBox(height: MoeSpacing.md),

          // G2 圆角用法示例（项目统一标准）
          Wrap(
            alignment: WrapAlignment.spaceEvenly,
            spacing: MoeSpacing.sm,
            runSpacing: MoeSpacing.md,
            children: [
              // 1) MoeG2Decoration（只负责绘制，不裁剪 child）
              _buildCornerBox(
                colors: colors,
                label: 'G2 装饰\n(MoeG2Decoration)',
                boxSize: boxSize,
                child: Container(
                  width: boxSize,
                  height: boxSize,
                  decoration: MoeG2Decoration(
                    radius: _cornerRadius,
                    color: colors.accentColor,
                  ),
                ),
              ),

              // 2) MoeG2ClipRRect（裁剪 child）
              _buildCornerBox(
                colors: colors,
                label: 'G2 裁剪\n(MoeG2ClipRRect)',
                boxSize: boxSize,
                child: MoeG2ClipRRect(
                  radius: _cornerRadius,
                  child: Container(
                    width: boxSize,
                    height: boxSize,
                    color: colors.accentColor,
                  ),
                ),
              ),

              // 3) 带边框的 MoeG2Decoration
              _buildCornerBox(
                colors: colors,
                label: 'G2 装饰 + 边框',
                boxSize: boxSize,
                child: Container(
                  width: boxSize,
                  height: boxSize,
                  decoration: MoeG2Decoration(
                    radius: _cornerRadius,
                    color: colors.accentColor,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.35),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: MoeSpacing.lg),

          // 大长方形对比（模拟弹窗）
          _buildDialogStyleDemo(colors),
          const SizedBox(height: MoeSpacing.md),

          // 说明文字
          Container(
            padding: const EdgeInsets.all(MoeSpacing.sm),
            decoration: MoeG2Decoration(
              radius: MoeRadii.sm,
              color: colors.surfaceAlt,
            ),
            child: Text(
              '普通圆角：标准圆弧，直边与圆角交接处有明显转折\n'
              'iOS Continuous：Flutter 内置，曲率过渡较平滑\n'
              'Figma G2：真正的 G2 连续曲线，曲率最柔和饱满',
              style: TextStyle(
                fontSize: 12,
                color: colors.textSecondary,
                height: 1.6,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCornerBox({
    required MoeColors colors,
    required String label,
    required double boxSize,
    required Widget child,
  }) {
    return Column(
      children: [
        child,
        const SizedBox(height: MoeSpacing.xs),
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: colors.textSecondary),
        ),
      ],
    );
  }

  /// 构建弹窗风格圆角对比（大长方形）
  Widget _buildDialogStyleDemo(MoeColors colors) {
    final screenWidth = MediaQuery.of(context).size.width;
    final dialogWidth = screenWidth * 0.8;
    const dialogHeight = 160.0;

    return Column(
      children: [
        // 1) MoeG2Decoration（只负责绘制，不裁剪 child）
        _buildDialogBox(
          colors: colors,
          label: 'G2 装饰 (MoeG2Decoration)',
          width: dialogWidth,
          height: dialogHeight,
          child: Container(
            width: dialogWidth,
            height: dialogHeight,
            decoration: MoeG2Decoration(
              radius: _cornerRadius,
              color: colors.accentColor,
            ),
          ),
        ),
        const SizedBox(height: MoeSpacing.sm),

        // 2) MoeG2ClipRRect（裁剪 child）
        _buildDialogBox(
          colors: colors,
          label: 'G2 裁剪 (MoeG2ClipRRect)',
          width: dialogWidth,
          height: dialogHeight,
          child: MoeG2ClipRRect(
            radius: _cornerRadius,
            child: Container(
              width: dialogWidth,
              height: dialogHeight,
              color: colors.accentColor,
            ),
          ),
        ),
        const SizedBox(height: MoeSpacing.sm),

        // 3) 带边框/阴影的 MoeG2Decoration
        _buildDialogBox(
          colors: colors,
          label: 'G2 装饰 + 边框/阴影',
          width: dialogWidth,
          height: dialogHeight,
          child: Container(
            width: dialogWidth,
            height: dialogHeight,
            decoration: MoeG2Decoration(
              radius: _cornerRadius,
              color: colors.accentColor,
              border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
              boxShadow: MoeShadows.card,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDialogBox({
    required MoeColors colors,
    required String label,
    required double width,
    required double height,
    required Widget child,
  }) {
    return Column(
      children: [
        child,
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(fontSize: 12, color: colors.textSecondary),
        ),
      ],
    );
  }

  /// 构建背景色对比展示
  Widget _buildBackgroundColorsDemo(MoeColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MoeSpacing.md),
      child: Column(
        children: [
          _buildColorRow('bgMain', '主背景色（页面底色）', colors.bgMain, colors),
          _buildColorRow('surface', '表面背景色', colors.surface, colors),
          _buildColorRow('surfaceAlt', '次级表面（略深）', colors.surfaceAlt, colors),
          _buildColorRow('panel', '容器背景（卡片/面板）', colors.panel, colors),
          _buildColorRow(
            'componentBackground',
            '组件背景（设置分组）',
            colors.componentBackground,
            colors,
          ),
          const SizedBox(height: MoeSpacing.sm),
          Container(
            padding: const EdgeInsets.all(MoeSpacing.sm),
            decoration: MoeG2Decoration(
              radius: MoeRadii.sm,
              color: colors.surfaceAlt,
            ),
            child: Text(
              '浅色模式：bgMain=#DAE1E5, surface=#F3F6F8, surfaceAlt=#E8EDF2, panel=#DAE5F1, component=白色\n'
              '暗色模式：bgMain=#1C1C1C, surface=#1C1C1C, surfaceAlt=#232830, panel=#333333, component=#333333',
              style: TextStyle(
                fontSize: 11,
                color: colors.textSecondary,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildColorRow(
    String name,
    String desc,
    Color color,
    MoeColors colors,
  ) {
    final hex =
        '#${color.toARGB32().toRadixString(16).substring(2).toUpperCase()}';
    return Padding(
      padding: const EdgeInsets.only(bottom: MoeSpacing.sm),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: MoeG2Decoration(
              radius: 8,
              color: color,
              border: Border.all(color: colors.border, width: 1),
            ),
          ),
          const SizedBox(width: MoeSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: MoeFontWeights.emphasis,
                    color: colors.text,
                  ),
                ),
                Text(
                  '$desc ($hex)',
                  style: TextStyle(fontSize: 12, color: colors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum _TransitionDemo {
  page('横向切页', 'CupertinoPageRoute', '新页面从右侧进入，返回时反向退出。可从左边缘滑动返回。'),
  transition(
    '自定义横向转场',
    'CupertinoPageTransition',
    '与横向切页外观接近；这里在自定义路由中复用官方转场。请点击返回按钮退出。',
  ),
  sheet('底部堆叠', 'showCupertinoSheet', '页面从底部升起。再打开一层，观察前一层上移并缩小；向下拖动可关闭。');

  const _TransitionDemo(this.label, this.api, this.description);

  final String label;
  final String api;
  final String description;
}

void _openTransitionDemo(
  BuildContext context,
  _TransitionDemo demo, {
  int depth = 1,
}) {
  Widget builder(BuildContext context) =>
      _TransitionDemoPage(demo: demo, depth: depth);

  switch (demo) {
    case _TransitionDemo.page:
      Navigator.of(context).push<void>(CupertinoPageRoute(builder: builder));
    case _TransitionDemo.transition:
      Navigator.of(context).push<void>(
        PageRouteBuilder<void>(
          transitionDuration: const Duration(milliseconds: 500),
          reverseTransitionDuration: const Duration(milliseconds: 500),
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionsBuilder: (context, animation, secondaryAnimation, child) =>
              CupertinoPageTransition(
                primaryRouteAnimation: animation,
                secondaryRouteAnimation: secondaryAnimation,
                linearTransition: false,
                child: child,
              ),
        ),
      );
    case _TransitionDemo.sheet:
      showCupertinoSheet<void>(context: context, builder: builder);
  }
}

class _TransitionDemoPage extends StatelessWidget {
  const _TransitionDemoPage({required this.demo, required this.depth});

  final _TransitionDemo demo;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return MoePageScaffold(
      backgroundColor: depth.isOdd ? colors.bgMain : colors.surfaceAlt,
      appBar: MoeAppBar(
        title: '${demo.label} · 第 $depth 层',
        showBackButton: true,
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(MoeSpacing.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    demo == _TransitionDemo.sheet
                        ? Icons.layers_outlined
                        : Icons.swipe_left_outlined,
                    size: 64,
                    color: colors.accentColor,
                  ),
                  const SizedBox(height: MoeSpacing.lg),
                  Text(
                    demo.api,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colors.text, fontSize: 20),
                  ),
                  const SizedBox(height: MoeSpacing.md),
                  Text(
                    demo.description,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colors.textSecondary, height: 1.6),
                  ),
                  const SizedBox(height: MoeSpacing.xl),
                  MoePrimaryButton(
                    label: '再打开一层',
                    onPressed: () =>
                        _openTransitionDemo(context, demo, depth: depth + 1),
                  ),
                  const SizedBox(height: MoeSpacing.md),
                  MoeSecondaryButton(
                    label: '返回上一层',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MovingPatternPainter extends CustomPainter {
  const _MovingPatternPainter({required this.animationValue});

  final double animationValue;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill;

    // 绘制几颗动态位移的几何装饰圆，提供丰富的背景图案供液态玻璃折射
    final cx1 = size.width * (0.25 + 0.3 * animationValue);
    final cy1 = size.height * (0.3 + 0.4 * (1 - animationValue));
    canvas.drawCircle(Offset(cx1, cy1), 45, paint);

    final cx2 = size.width * (0.75 - 0.35 * animationValue);
    final cy2 = size.height * (0.65 - 0.3 * animationValue);
    canvas.drawCircle(
      Offset(cx2, cy2),
      60,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.12)
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(_MovingPatternPainter oldDelegate) =>
      oldDelegate.animationValue != animationValue;
}

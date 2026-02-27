import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:figma_squircle/figma_squircle.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../../core/utils/data_image.dart';
import '../../../../features/chat/domain/conversation.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/theme/tokens.dart';

class ChatBackgroundSettingsResult {
  final String? backgroundImage;
  final bool clearBackgroundImage;
  final double? maskOpacity;
  final bool clearMaskOpacity;
  final double? blurSigma;
  final bool clearBlurSigma;

  const ChatBackgroundSettingsResult({
    this.backgroundImage,
    this.clearBackgroundImage = false,
    this.maskOpacity,
    this.clearMaskOpacity = false,
    this.blurSigma,
    this.clearBlurSigma = false,
  });
}

class ChatBackgroundSettingsPage extends StatefulWidget {
  final Conversation conversation;

  const ChatBackgroundSettingsPage({
    super.key,
    required this.conversation,
  });

  @override
  State<ChatBackgroundSettingsPage> createState() =>
      _ChatBackgroundSettingsPageState();
}

class _ChatBackgroundSettingsPageState
    extends State<ChatBackgroundSettingsPage> {
  static const double _defaultMaskOpacity = 0.8;
  static const double _defaultBlurSigma = 0.0;

  String? _backgroundImage;
  Uint8List? _backgroundBytes;
  late double _maskOpacity;
  late double _blurSigma;
  bool _previewDark = false;

  @override
  void initState() {
    super.initState();
    final initialRaw = widget.conversation.chatBackgroundImage?.trim();
    _backgroundImage =
        (initialRaw == null || initialRaw.isEmpty) ? null : initialRaw;
    _backgroundBytes = decodeDataImage(_backgroundImage);
    _maskOpacity =
        (widget.conversation.chatBackgroundMaskOpacity ?? _defaultMaskOpacity)
            .clamp(0.0, 1.0);
    _blurSigma =
        (widget.conversation.chatBackgroundBlurSigma ?? _defaultBlurSigma)
            .clamp(0.0, 30.0);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() =>
            _previewDark = Theme.of(context).brightness == Brightness.dark);
      }
    });
  }

  bool get _hasBackground =>
      _backgroundImage != null && _backgroundImage!.trim().isNotEmpty;

  Future<void> _pickBackgroundImage() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.first;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) return;

    setState(() {
      _backgroundBytes = bytes;
      _backgroundImage = buildDataImage(bytes, fileName: file.name);
    });
  }

  void _clearBackgroundImage() {
    setState(() {
      _backgroundImage = null;
      _backgroundBytes = null;
    });
  }

  void _resetToDefault() {
    setState(() {
      _backgroundImage = null;
      _backgroundBytes = null;
      _maskOpacity = _defaultMaskOpacity;
      _blurSigma = _defaultBlurSigma;
    });
  }

  void _save() {
    final raw = _backgroundImage?.trim();
    final hasBackground = raw != null && raw.isNotEmpty;
    Navigator.of(context).pop(
      ChatBackgroundSettingsResult(
        backgroundImage: hasBackground ? raw : null,
        clearBackgroundImage: !hasBackground,
        maskOpacity: hasBackground ? _maskOpacity : null,
        clearMaskOpacity: !hasBackground,
        blurSigma: hasBackground ? _blurSigma : null,
        clearBlurSigma: !hasBackground,
      ),
    );
  }

  // ─── 背景图片构建 ───

  Widget? _buildBackgroundImage() {
    final raw = _backgroundImage?.trim();
    if (raw == null || raw.isEmpty) return null;

    if (_backgroundBytes != null) {
      return Image.memory(_backgroundBytes!,
          fit: BoxFit.cover, gaplessPlayback: true,
          errorBuilder: (_, __, ___) => const SizedBox.shrink());
    }

    final bytes = decodeDataImage(raw);
    if (bytes != null) {
      return Image.memory(bytes,
          fit: BoxFit.cover, gaplessPlayback: true,
          errorBuilder: (_, __, ___) => const SizedBox.shrink());
    }

    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return Image.network(raw,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const SizedBox.shrink());
    }
    if (raw.startsWith('assets/') || raw.startsWith('packages/')) {
      return Image.asset(raw,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const SizedBox.shrink());
    }
    return Image.file(File(raw),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const SizedBox.shrink());
  }

  // ─── UI ───

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Scaffold(
      backgroundColor: colors.surface,
      body: Column(
        children: [
          // ── 上方：聊天界面缩略预览 ──
          Expanded(child: _buildPreviewArea(colors)),

          // ── 下方：底部弹窗风格设置面板 ──
          _buildSettingsSheet(colors),
        ],
      ),
    );
  }

  // ─── 预览区：等比缩小的聊天界面 ───

  Widget _buildPreviewArea(MoeColors colors) {
    final topPadding = MediaQuery.paddingOf(context).top;

    return Container(
      color: colors.surface,
      padding: EdgeInsets.only(top: topPadding + 8, left: 24, right: 24, bottom: 12),
      child: Column(
        children: [
          // 真正的返回 / 保存按钮行
          _buildTopBar(colors),
          const SizedBox(height: 12),

          // 聊天界面缩略图
          Expanded(child: _buildChatMiniature(colors)),
        ],
      ),
    );
  }

  Widget _buildTopBar(MoeColors colors) {
    return Row(
      children: [
        IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: Icon(Icons.arrow_back, color: colors.text),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        ),
        Expanded(
          child: Text(
            '聊天背景设置',
            style: TextStyle(
              color: colors.text,
              fontSize: 17,
              fontWeight: MoeFontWeights.emphasis,
            ),
          ),
        ),
        TextButton(
          onPressed: _save,
          child: Text(
            '保存',
            style: TextStyle(
              color: colors.accentColor,
              fontWeight: MoeFontWeights.emphasis,
            ),
          ),
        ),
      ],
    );
  }

  /// 等比缩小的聊天界面模型
  Widget _buildChatMiniature(MoeColors colors) {
    final darkMode = _previewDark;
    final fallbackColor = darkMode
        ? const Color(0xFF151A22)
        : const Color(0xFFF5F7FA);
    final textColor = darkMode ? Colors.white : const Color(0xFF1E2A3A);
    final mutedColor = darkMode ? Colors.white54 : Colors.black38;
    final image = _buildBackgroundImage();

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          color: fallbackColor,
          border: Border.all(
            color: colors.border.withValues(alpha: 0.3),
            width: 0.5,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 背景图 + 模糊
            if (image != null) ...[
              if (_blurSigma > 0.1)
                ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(
                    sigmaX: _blurSigma,
                    sigmaY: _blurSigma,
                    tileMode: TileMode.decal,
                  ),
                  child: image,
                )
              else
                image,
              // 遮罩
              IgnorePointer(
                child: Container(
                  color: fallbackColor.withValues(alpha: _maskOpacity),
                ),
              ),
            ],

            // 模拟聊天 UI
            Column(
              children: [
                // ── 模拟顶栏 ──
                Container(
                  height: 44,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: darkMode ? 0.2 : 0.08),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.arrow_back, size: 16, color: textColor),
                      const SizedBox(width: 8),
                      // 模拟头像
                      Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: mutedColor.withValues(alpha: 0.3),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.person, size: 16, color: mutedColor),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.conversation.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: textColor,
                            fontSize: 13,
                            fontWeight: MoeFontWeights.emphasis,
                          ),
                        ),
                      ),
                      Icon(Icons.more_horiz, size: 16, color: textColor),
                    ],
                  ),
                ),

                // ── 模拟聊天消息区域 ──
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // 时间戳
                        Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '14:30',
                              style: TextStyle(color: mutedColor, fontSize: 10),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        // 对方消息
                        Align(
                          alignment: Alignment.centerLeft,
                          child: _mockBubble(
                            '这是一条消息，检查文字可读性',
                            darkMode: darkMode,
                            isMe: false,
                          ),
                        ),
                        const SizedBox(height: 8),
                        // 自己的消息
                        Align(
                          alignment: Alignment.centerRight,
                          child: _mockBubble(
                            '好的，收到了',
                            darkMode: darkMode,
                            isMe: true,
                          ),
                        ),
                        const SizedBox(height: 8),
                        // 对方消息 2
                        Align(
                          alignment: Alignment.centerLeft,
                          child: _mockBubble(
                            '嗯嗯~',
                            darkMode: darkMode,
                            isMe: false,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // ── 模拟底部输入栏 ──
                Container(
                  height: 42,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: darkMode ? 0.18 : 0.05),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.add_rounded, size: 18, color: mutedColor),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Container(
                          height: 28,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: (darkMode ? Colors.white : Colors.black)
                                .withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '说点什么...',
                            style: TextStyle(color: mutedColor, fontSize: 11),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(Icons.arrow_upward_rounded, size: 18, color: mutedColor),
                    ],
                  ),
                ),
              ],
            ),

            // 无背景时的悬浮选图按钮
            if (!_hasBackground)
              Center(
                child: OutlinedButton.icon(
                  onPressed: _pickBackgroundImage,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  label: const Text('选择背景图片'),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: colors.surface.withValues(alpha: 0.85),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _mockBubble(
    String text, {
    required bool darkMode,
    required bool isMe,
  }) {
    final bg = isMe
        ? (darkMode
            ? const Color(0xFF5A91E2).withValues(alpha: 0.72)
            : const Color(0xFF74A7F2).withValues(alpha: 0.8))
        : (darkMode
            ? Colors.black.withValues(alpha: 0.28)
            : Colors.white.withValues(alpha: 0.78));
    final fg = darkMode ? Colors.white : const Color(0xFF2A3240);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 200),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
        ),
        child: Text(
          text,
          style: TextStyle(color: fg, fontSize: 12, height: 1.3),
        ),
      ),
    );
  }

  // ─── 底部弹窗风格设置面板 ───

  Widget _buildSettingsSheet(MoeColors colors) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sheetBgColor = isDark ? colors.surface : Colors.white;

    const sheetBorderRadius = SmoothBorderRadius.vertical(
      top: SmoothRadius(cornerRadius: 16, cornerSmoothing: 0.6),
    );

    return Container(
      decoration: ShapeDecoration(
        color: sheetBgColor,
        shape: SmoothRectangleBorder(
          borderRadius: sheetBorderRadius,
          side: BorderSide(
            color: colors.border.withValues(alpha: isDark ? 0.3 : 0.15),
            width: 0.5,
          ),
        ),
        shadows: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: MoeG2ClipRRect.borderRadius(
        borderRadius: sheetBorderRadius,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 拖动指示器
              Container(
                margin: const EdgeInsets.only(top: 8, bottom: 4),
                width: 36,
                height: 4,
                decoration: MoeG2Decoration(
                  radius: 2,
                  color: colors.muted.withValues(alpha: 0.3),
                ),
              ),

              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── 背景图片操作 ──
                    if (_hasBackground)
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _pickBackgroundImage,
                              icon: const Icon(Icons.photo_library_outlined,
                                  size: 18),
                              label: const Text('更换图片'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _clearBackgroundImage,
                              icon: const Icon(Icons.close, size: 18),
                              label: const Text('清除'),
                            ),
                          ),
                        ],
                      ),

                    if (_hasBackground) const SizedBox(height: 14),

                    // ── 预览模式切换 ──
                    _buildLabel(colors, '预览模式'),
                    const SizedBox(height: 6),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('浅色')),
                        ButtonSegment(value: true, label: Text('深色')),
                      ],
                      selected: {_previewDark},
                      onSelectionChanged: (s) =>
                          setState(() => _previewDark = s.first),
                      showSelectedIcon: false,
                      style: SegmentedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),

                    const SizedBox(height: 12),

                    // ── 遮罩强度 ──
                    _buildLabel(
                        colors, '遮罩强度  ${(_maskOpacity * 100).round()}%'),
                    Slider(
                      value: _maskOpacity,
                      min: 0.0,
                      max: 1.0,
                      divisions: 20,
                      onChanged: _hasBackground
                          ? (v) => setState(() => _maskOpacity = v)
                          : null,
                    ),

                    // ── 模糊度 ──
                    _buildLabel(colors, '模糊度  ${_blurSigma.round()}'),
                    Slider(
                      value: _blurSigma,
                      min: 0.0,
                      max: 30.0,
                      divisions: 30,
                      onChanged: _hasBackground
                          ? (v) => setState(() => _blurSigma = v)
                          : null,
                    ),

                    // ── 恢复默认 ──
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: _resetToDefault,
                        icon: const Icon(Icons.restore, size: 18),
                        label: const Text('恢复默认'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLabel(MoeColors colors, String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: MoeFontWeights.emphasis,
        color: colors.text,
      ),
    );
  }
}

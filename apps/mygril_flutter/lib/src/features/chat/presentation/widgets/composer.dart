/// 消息输入组件
/// 
/// 更新记录：
/// - 2025-12-06: 接入皮肤系统
/// - 2025-12-31: 拆分功能菜单和模型选择器到独立文件
library;
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../ui/theme/skin_provider.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/moe_toast.dart';
import '../../../settings/app_settings.dart';

/// 消息输入组件
class Composer extends ConsumerStatefulWidget {
  final bool disabled;
  final ValueChanged<String> onSend;
  final ValueChanged<String>? onImageSelected; // 图片路径回调
  const Composer({
    super.key,
    required this.onSend,
    this.disabled = false,
    this.onImageSelected,
  });

  @override
  ConsumerState<Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<Composer> {
  final _ctrl = TextEditingController();
  final _inputFocus = FocusNode();
  // 合并用户单轮消息：3秒空闲聚合定时器
  Timer? _idleTimer;
  static const int _idleSeconds = 3;
  // 选中的图片路径（用于预览）
  String? _selectedImagePath;

  @override
  void initState() {
    super.initState();
    // 监听文本变化以便空闲聚合（不依赖 TextField.onChanged，兼容性更高）
    _ctrl.addListener(() {
      if (!mounted) return;
      if (widget.disabled) return;
      _idleTimer?.cancel();
      _idleTimer = Timer(const Duration(seconds: _idleSeconds), _tryAutoSend);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _inputFocus.dispose();
    _idleTimer?.cancel();
    super.dispose();
  }

  // 拼音/组合输入检测，避免误触发
  bool _isComposingActive() {
    final composing = _ctrl.value.composing;
    return composing.isValid && !composing.isCollapsed;
  }

  // 空闲到点后尝试发送；若仍在组合中，则顺延1秒
  void _tryAutoSend() {
    if (widget.disabled) return;
    if (_isComposingActive()) {
      _idleTimer = Timer(const Duration(seconds: 1), _tryAutoSend);
      return;
    }
    final t = _ctrl.text.trim();
    if (t.isEmpty) return;
    widget.onSend(t);
    _ctrl.clear();
  }

  void _submit() {
    _idleTimer?.cancel();

    // 如果有选中的图片，发送图片
    if (_selectedImagePath != null && widget.onImageSelected != null) {
      widget.onImageSelected!(_selectedImagePath!);
      setState(() {
        _selectedImagePath = null;
      });
      _ctrl.clear();
      return;
    }

    // 否则发送文本消息
    final t = _ctrl.text.trim();
    if (t.isEmpty || widget.disabled) return;
    widget.onSend(t);
    _ctrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final skin = context.skin;
    final colors = context.moeColors;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final inputBgColor = isDark ? colors.panel : Colors.white;

    return Container(
      color: colors.surface,
      child: SafeArea(
        top: false,
        bottom: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 图片预览区域（如果有选中的图片）
            if (_selectedImagePath != null) _buildImagePreview(),
            // 输入栏区域
            Container(
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border(
                  top: BorderSide(color: colors.border, width: 1),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // 输入框
                  Expanded(
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 42),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: skin.inputDecoration(colors).copyWith(
                        color: inputBgColor,
                      ),
                      child: TextField(
                        controller: _ctrl,
                        focusNode: _inputFocus,
                        minLines: 1,
                        maxLines: 4,
                        style: const TextStyle(fontSize: 16, height: 1.5),
                        decoration: InputDecoration.collapsed(
                          hintText: '说点什么...',
                          hintStyle: TextStyle(color: colors.muted),
                        ),
                        enabled: !widget.disabled,
                        onSubmitted: (_) => _submit(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 发送按钮
                  _buildSendButton(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建图片预览组件
  Widget _buildImagePreview() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.moeColors.surface,
        border: Border(
          top: BorderSide(color: context.moeColors.border, width: 1),
        ),
      ),
      child: Row(
        children: [
          // 图片缩略图
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  File(_selectedImagePath!),
                  width: 80,
                  height: 80,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.broken_image, color: Colors.grey),
                  ),
                ),
              ),
              // 关闭按钮
              Positioned(
                top: -4,
                right: -4,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () {
                      setState(() {
                        _selectedImagePath = null;
                      });
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.close,
                        size: 16,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          // 图片信息
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '图片附件',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: context.moeColors.text,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '点击发送按钮发送图片',
                  style: TextStyle(
                    fontSize: 12,
                    color: context.moeColors.text.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }



  Widget _buildSendButton() {
    return Material(
      color: moePrimary,
      shape: const CircleBorder(),
      elevation: 2,
      child: InkWell(
        onTap: widget.disabled ? null : _submit,
        customBorder: const CircleBorder(),
        child: Container(
          width: 42,
          height: 42,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: [moeHeaderGradientStart, moeHeaderGradientEnd],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

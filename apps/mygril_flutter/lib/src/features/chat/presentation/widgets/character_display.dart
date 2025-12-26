import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:mygril_flutter/src/core/utils/data_image.dart';

/// 角色卡片展示组件 - 高斯模糊背景风格
/// 
/// 更新记录：
/// - 2025-12-07: 重构为高斯模糊背景 + 居中立绘 + 底部信息布局
///   - 背景：立绘放大模糊作为背景
///   - 主图：居中缩小的清晰立绘
///   - 信息：底部渐变遮罩 + 角色名 + 简介
class CharacterDisplay extends StatelessWidget {
  final String? characterImage;
  final String displayName;
  final String? description; // 角色简介

  const CharacterDisplay({
    super.key,
    this.characterImage,
    required this.displayName,
    this.description,
  });

  @override
  Widget build(BuildContext context) {
    // 海报比例 3:4
    return AspectRatio(
      aspectRatio: 3 / 4,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 第1层：高斯模糊背景
            _buildBlurredBackground(),
            // 第2层：暗角渐变（增强层次感）
            _buildVignetteOverlay(),
            // 第3层：居中清晰立绘
            _buildCenterImage(),
            // 第4层：底部信息区（渐变遮罩 + 文字）
            _buildInfoOverlay(),
          ],
        ),
      ),
    );
  }

  /// 构建高斯模糊背景层
  Widget _buildBlurredBackground() {
    return Positioned.fill(
      child: ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: Transform.scale(
          scale: 1.3, // 放大避免边缘留白
          child: _buildImageWidget(fit: BoxFit.cover),
        ),
      ),
    );
  }

  /// 构建暗角渐变（模拟参考图的效果）
  Widget _buildVignetteOverlay() {
    return Positioned.fill(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 1.0,
            colors: [
              Colors.transparent,
              Colors.black.withOpacity(0.3),
            ],
            stops: const [0.5, 1.0],
          ),
        ),
      ),
    );
  }

  /// 构建居中清晰立绘
  Widget _buildCenterImage() {
    return Positioned.fill(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 80), // 底部留出信息区空间
        child: Center(
          child: _buildImageWidget(
            fit: BoxFit.contain,
            addShadow: true,
          ),
        ),
      ),
    );
  }

  /// 构建底部信息区
  Widget _buildInfoOverlay() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 32, 16, 16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.black.withOpacity(0.7),
            ],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 角色名称
            Text(
              displayName,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                shadows: [
                  Shadow(color: Colors.black54, blurRadius: 4),
                ],
              ),
            ),
            // 简介（如果有）
            if (description != null && description!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                description!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withOpacity(0.85),
                  height: 1.4,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 通用图片构建方法
  Widget _buildImageWidget({required BoxFit fit, bool addShadow = false}) {
    if (characterImage == null) {
      return _buildPlaceholder();
    }

    Widget image;
    final bytes = decodeDataImage(characterImage!);
    if (bytes != null) {
      image = Image.memory(bytes, fit: fit);
    } else {
      image = Image.asset(
        characterImage!,
        fit: fit,
        errorBuilder: (_, __, ___) => _buildPlaceholder(),
      );
    }

    if (addShadow) {
      return Container(
        decoration: BoxDecoration(
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 20,
              spreadRadius: 5,
            ),
          ],
        ),
        child: image,
      );
    }
    return image;
  }

  /// 占位图
  Widget _buildPlaceholder() {
    return Container(
      color: Colors.grey[800],
      child: const Center(
        child: Icon(
          Icons.person_outline,
          size: 80,
          color: Colors.white54,
        ),
      ),
    );
  }
}

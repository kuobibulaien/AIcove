import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';
import '../theme/tokens.dart';

/// 通用的图片裁剪弹窗
/// 用于头像等场景的图片裁剪
class ImageCropDialog extends StatefulWidget {
  final Uint8List imageBytes;
  final String fileName;

  const ImageCropDialog({
    super.key,
    required this.imageBytes,
    required this.fileName,
  });

  @override
  State<ImageCropDialog> createState() => _ImageCropDialogState();
}

class _ImageCropDialogState extends State<ImageCropDialog> with SingleTickerProviderStateMixin {
  final CropController _cropController = CropController();
  bool _isImageReady = false;
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeIn,
    );
    
    // 延迟一小段时间让图片准备好，然后开始淡入动画
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) {
        setState(() {
          _isImageReady = true;
        });
        _fadeController.forward();
      }
    });
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 加载指示器（在图片准备好之前显示）
          if (!_isImageReady)
            const Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
          
          // 裁剪区域（淡入动画）
          if (_isImageReady)
            FadeTransition(
              opacity: _fadeAnimation,
              child: Positioned.fill(
                child: Crop(
                  controller: _cropController,
                  image: widget.imageBytes,
                  onCropped: (result) {
                    if (result is CropSuccess) {
                      Navigator.pop(context, result.croppedImage);
                    } else if (result is CropFailure) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('裁剪失败: ${result.cause}'),
                          duration: const Duration(seconds: 1),
                        ),
                      );
                    }
                  },
                  aspectRatio: 1.0,
                  // 使用矩形裁剪 UI，并配合圆角与页面中头像风格统一
                  withCircleUi: false,
                  interactive: true,
                  initialRectBuilder: InitialRectBuilder.withSizeAndRatio(
                    size: 0.8,
                    aspectRatio: 1.0,
                  ),
                  baseColor: Colors.black,
                  maskColor: Colors.black.withOpacity(0.6),
                  radius: radiusBubble.x,
                  fixCropRect: true,
                  // 隐藏裁剪框的控制点
                  cornerDotBuilder: (size, edgeAlignment) => const SizedBox.shrink(),
                ),
              ),
            ),
          
          // 顶部工具栏（淡入动画）
          if (_isImageReady)
            FadeTransition(
              opacity: _fadeAnimation,
              child: Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + 8,
                left: 16,
                right: 16,
                bottom: 16,
              ),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(0.7),
                    Colors.transparent,
                  ],
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const Text(
                    '裁剪头像',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.check, color: Colors.white),
                    onPressed: () => _cropController.crop(),
                  ),
                ],
              ),
            ),
              ),
            ),
          
          // 底部提示（淡入动画）
          if (_isImageReady)
            FadeTransition(
              opacity: _fadeAnimation,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.only(top: 80),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 占位空间，推算裁剪区域大小
                      SizedBox(
                        height: MediaQuery.of(context).size.width * 0.8,
                      ),
                      const SizedBox(height: 24),
                      // 提示文字
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.6),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text(
                          '双指缩放和移动图片以调整裁剪区域',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

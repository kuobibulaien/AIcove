import 'dart:io';
import 'package:flutter/material.dart';
import 'package:mygril_flutter/src/core/models/message_block.dart';

/// 表情包显示 Widget
/// 用于在聊天界面显示表情包
class EmojiWidget extends StatelessWidget {
  final EmojiBlock block;

  /// 表情包尺寸
  final double size;

  /// 是否显示加载指示器
  final bool showLoading;

  /// 加载失败时的占位符
  final Widget? errorPlaceholder;

  const EmojiWidget({
    super.key,
    required this.block,
    this.size = 120.0,
    this.showLoading = true,
    this.errorPlaceholder,
  });

  @override
  Widget build(BuildContext context) {
    // 1. 检查路径
    if (block.path.isEmpty) {
      return _buildError('路径为空');
    }

    // 2. 根据路径类型显示
    if (block.path.startsWith('http://') || block.path.startsWith('https://')) {
      // 网络图片
      return _buildNetworkImage();
    } else {
      // 本地文件
      return _buildLocalImage();
    }
  }

  /// 构建网络图片
  Widget _buildNetworkImage() {
    return Image.network(
      block.path,
      width: size,
      height: size,
      fit: BoxFit.contain,
      loadingBuilder: showLoading
          ? (context, child, loadingProgress) {
              if (loadingProgress == null) return child;
              return _buildLoadingIndicator();
            }
          : null,
      errorBuilder: (context, error, stackTrace) {
        return errorPlaceholder ?? _buildError('加载失败');
      },
    );
  }

  /// 构建本地图片
  Widget _buildLocalImage() {
    final file = File(block.path);

    // 检查文件是否存在
    if (!file.existsSync()) {
      return errorPlaceholder ?? _buildError('文件不存在');
    }

    return Image.file(
      file,
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) {
        return errorPlaceholder ?? _buildError('加载失败');
      },
    );
  }

  /// 构建加载指示器
  Widget _buildLoadingIndicator() {
    return SizedBox(
      width: size,
      height: size,
      child: const Center(
        child: CircularProgressIndicator(),
      ),
    );
  }

  /// 构建错误占位符
  Widget _buildError(String message) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.broken_image,
            size: size * 0.4,
            color: Colors.grey[400],
          ),
          const SizedBox(height: 4),
          Text(
            message,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[600],
            ),
          ),
        ],
      ),
    );
  }
}

/// 可交互的表情包 Widget
/// 支持长按、点击等交互
class InteractiveEmojiWidget extends StatelessWidget {
  final EmojiBlock block;
  final double size;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const InteractiveEmojiWidget({
    super.key,
    required this.block,
    this.size = 120.0,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress ?? () => _showEmojiInfo(context),
      child: EmojiWidget(
        block: block,
        size: size,
      ),
    );
  }

  /// 显示表情包信息（长按时）
  void _showEmojiInfo(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('表情包信息'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 显示表情包
            Center(
              child: EmojiWidget(
                block: block,
                size: 150,
              ),
            ),
            const SizedBox(height: 16),
            // 显示匹配信息
            if (block.matchedTag != null) ...[
              Text('匹配标签: ${block.matchedTag}'),
              const SizedBox(height: 8),
            ],
            if (block.originalText != null) ...[
              Text('原始文本: ${block.originalText}'),
              const SizedBox(height: 8),
            ],
            Text('表情包ID: ${block.emojiId}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

/// 表情包网格视图（用于表情包选择器）
class EmojiGridView extends StatelessWidget {
  final List<EmojiBlock> emojiBlocks;
  final double itemSize;
  final int crossAxisCount;
  final Function(EmojiBlock)? onEmojiTap;

  const EmojiGridView({
    super.key,
    required this.emojiBlocks,
    this.itemSize = 80.0,
    this.crossAxisCount = 4,
    this.onEmojiTap,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: emojiBlocks.length,
      itemBuilder: (context, index) {
        final block = emojiBlocks[index];
        return GestureDetector(
          onTap: () => onEmojiTap?.call(block),
          child: EmojiWidget(
            block: block,
            size: itemSize,
          ),
        );
      },
    );
  }
}

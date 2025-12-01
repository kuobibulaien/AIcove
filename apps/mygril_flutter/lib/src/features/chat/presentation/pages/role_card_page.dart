/// 角色卡页面 - 以海报网格形式展示和管理角色
/// 
/// 架构说明（遵循 DRY 原则）：
/// - RoleCardPage: 完整页面（带 AppBar），供窄屏模式使用
/// - RoleCardContent: 内容组件（无 AppBar），供宽屏模式嵌入使用
/// 
/// 更新记录：
/// - 2025-12-01: 创建角色卡页面，使用网格布局展示角色海报卡片
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/utils/data_image.dart';
import '../../domain/conversation.dart';
import '../../providers2.dart';

/// 角色卡页面 - 带 AppBar 的完整页面（窄屏使用）
class RoleCardPage extends StatelessWidget {
  const RoleCardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: colors.headerColor,
        foregroundColor: colors.headerContentColor,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(borderWidth),
          child: Container(
            color: colors.borderLight,
            height: borderWidth,
          ),
        ),
        title: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Text(
            '角色卡',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 24,
              color: colors.headerContentColor,
              letterSpacing: 0.8,
            ),
          ),
        ),
        centerTitle: false,
        actions: [
          // 新建角色按钮
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => context.go('/contact/new'),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.all(8),
                child: Icon(Icons.add, color: colors.headerContentColor, size: 26),
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      backgroundColor: colors.surface,
      body: const RoleCardContent(),
    );
  }
}

/// 角色卡内容 - 网格布局展示角色海报（无 AppBar，可嵌入其他布局）
class RoleCardContent extends ConsumerWidget {
  const RoleCardContent({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    final conversationsAsync = ref.watch(conversationsProvider);

    return conversationsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('加载失败: $e')),
      data: (conversations) {
        if (conversations.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.style_outlined, size: 64, color: colors.textSecondary),
                const SizedBox(height: 16),
                Text('暂无角色', style: TextStyle(color: colors.textSecondary)),
                const SizedBox(height: 8),
                Text(
                  '点击右上角 + 创建新角色',
                  style: TextStyle(color: colors.muted, fontSize: 13),
                ),
              ],
            ),
          );
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            // 根据宽度计算列数：每列最小 160px，最大 200px
            final crossAxisCount = (constraints.maxWidth / 180).floor().clamp(2, 6);
            
            return GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.7, // 海报比例：宽高比约 7:10
              ),
              itemCount: conversations.length,
              itemBuilder: (context, index) {
                final conv = conversations[index];
                return _RoleCard(
                  conversation: conv,
                  onTap: () {
                    // 宽屏模式：设置活跃对话
                    ref.read(activeConversationIdProvider.notifier).state = conv.id;
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

/// 单个角色海报卡片
class _RoleCard extends StatelessWidget {
  final Conversation conversation;
  final VoidCallback onTap;

  const _RoleCard({
    required this.conversation,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.all(radiusBubble),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.all(radiusBubble),
            color: isDark ? colors.panel : colors.surfaceAlt,
            border: Border.all(color: colors.divider, width: borderWidth),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 背景立绘/头像
              _buildBackground(context),
              // 渐变遮罩
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 80,
                child: Container(
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
                ),
              ),
              // 角色信息
              Positioned(
                left: 8,
                right: 8,
                bottom: 8,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 组织标签
                    if (conversation.organization != null && 
                        conversation.organization!.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(bottom: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: colors.primary.withOpacity(0.8),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          conversation.organization!,
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    // 角色名
                    Text(
                      conversation.displayName,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        shadows: [
                          Shadow(
                            color: Colors.black54,
                            blurRadius: 4,
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              // 置顶标记
              if (conversation.isPinned)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: colors.focus.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Icon(
                      Icons.push_pin,
                      size: 12,
                      color: Colors.white,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 构建背景图片（优先立绘，其次头像，最后文字占位）
  Widget _buildBackground(BuildContext context) {
    final colors = context.moeColors;

    // 优先尝试立绘
    final charImage = conversation.characterImage;
    if (charImage != null && charImage.isNotEmpty) {
      final charBytes = decodeDataImage(charImage);
      if (charBytes != null) {
        return Image.memory(charBytes, fit: BoxFit.cover);
      }
      return Image.asset(
        charImage,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildAvatarOrFallback(context),
      );
    }

    return _buildAvatarOrFallback(context);
  }

  /// 构建头像或文字占位
  Widget _buildAvatarOrFallback(BuildContext context) {
    final colors = context.moeColors;
    
    final avatar = conversation.avatarUrl;
    if (avatar != null && avatar.isNotEmpty) {
      final avatarBytes = decodeDataImage(avatar);
      if (avatarBytes != null) {
        return Image.memory(avatarBytes, fit: BoxFit.cover);
      }
      if (avatar.startsWith('http')) {
        return Image.network(avatar, fit: BoxFit.cover);
      }
      return Image.asset(
        avatar,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildLetterFallback(context),
      );
    }

    return _buildLetterFallback(context);
  }

  /// 文字占位
  Widget _buildLetterFallback(BuildContext context) {
    final colors = context.moeColors;
    final letter = conversation.displayName.isNotEmpty 
        ? conversation.displayName[0] 
        : '新';
    
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colors.primary.withOpacity(0.3),
            colors.primary.withOpacity(0.1),
          ],
        ),
      ),
      child: Center(
        child: Text(
          letter,
          style: TextStyle(
            fontSize: 48,
            fontWeight: FontWeight.bold,
            color: colors.primary.withOpacity(0.5),
          ),
        ),
      ),
    );
  }
}
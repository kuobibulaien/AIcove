import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mygril_flutter/src/core/utils/image_preheat_queue.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../providers2.dart';
import '../../domain/conversation.dart';
import '../../../../core/models/message_block.dart';
import 'character_list_item.dart';
import 'momotalk_sort_dialog.dart';
import '../../../../ui/theme/tokens.dart';

/// 联系人列表内容组件 - 纯内容展示，无AppBar（应用DRY原则）
/// 可复用于小屏和大屏布局
class ContactsListContent extends ConsumerWidget {
  /// 自定义点击回调（可选）
  /// 如果不提供，则使用默认行为（跳转到聊天页面）
  final void Function(String conversationId, WidgetRef ref)? onContactTap;

  /// 搜索关键字（可选）——用于前端本地过滤（按显示名）
  final String? searchQuery;
  final SortMode sortMode;
  final bool isAscending;

  const ContactsListContent({
    super.key,
    this.onContactTap,
    this.searchQuery,
    this.sortMode = SortMode.latest,
    this.isAscending = false,
  });

  List<ImageProvider> _collectAvatarProviders(Conversation conv) {
    final images = <ImageProvider>[];

    final avatarUrl = (conv.avatarUrl ?? conv.characterImage)?.trim();
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      final isNetwork =
          avatarUrl.startsWith('http://') || avatarUrl.startsWith('https://');
      final isAsset =
          avatarUrl.startsWith('assets/') || avatarUrl.startsWith('packages/');
      if (isNetwork) {
        images.add(CachedNetworkImageProvider(avatarUrl));
      } else if (isAsset) {
        images.add(AssetImage(avatarUrl));
      }
    }

    return images;
  }

  List<ImageProvider> _collectConversationPreviewProviders(
    Conversation conv, {
    required int maxMessagesToScan,
    required int maxImagesToCache,
  }) {
    final images = <ImageProvider>[];
    images.addAll(_collectAvatarProviders(conv));

    final messages = conv.messages;
    final start = messages.length > maxMessagesToScan
        ? messages.length - maxMessagesToScan
        : 0;
    for (var i = start;
        i < messages.length && images.length < maxImagesToCache;
        i++) {
      final blocks = messages[i].blocks;
      if (blocks == null) continue;

      for (final block in blocks) {
        if (images.length >= maxImagesToCache) break;

        if (block is ImageBlock) {
          final url = block.url;
          final localPath = block.localPath;
          if (url != null && url.isNotEmpty) {
            images.add(CachedNetworkImageProvider(url));
          } else if (localPath != null && localPath.isNotEmpty) {
            images.add(FileImage(File(localPath)));
          }
        } else if (block is EmojiBlock) {
          final path = block.path.trim();
          if (path.isEmpty) continue;
          final isNetwork =
              path.startsWith('http://') || path.startsWith('https://');
          final isAsset =
              path.startsWith('assets/') || path.startsWith('packages/');
          if (isNetwork) {
            images.add(CachedNetworkImageProvider(path));
          } else if (isAsset) {
            images.add(AssetImage(path));
          }
        }
      }
    }

    return images;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listAsync = ref.watch(conversationsProvider);
    return listAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('加载失败: $e')),
      data: (list) {
        final preheatQueue = ref.read(imagePreheatQueueProvider);

        // 按搜索关键字进行本地过滤（大小写不敏感）
        final q = (searchQuery ?? '').trim().toLowerCase();
        var filtered = q.isEmpty
            ? list
            : [
                for (final c in list)
                  if (c.displayName.toLowerCase().contains(q)) c,
              ];

        // 排序：置顶的在前，然后根据 sortMode 和 isAscending 排序
        filtered = [...filtered]..sort((a, b) {
            // 1. 置顶优先
            if (a.isPinned != b.isPinned) {
              return a.isPinned ? -1 : 1;
            }

            int result;
            switch (sortMode) {
              case SortMode.name:
                result = a.displayName.compareTo(b.displayName);
              case SortMode.latest:
                result = a.updatedAt.compareTo(b.updatedAt);
            }

            // 如果是最新消息模式，默认是倒序（最新的在上面），所以 isAscending=false 时反转
            // 如果是名字模式，默认是正序（A-Z），所以 isAscending=true 时保持，false 时反转
            // 这里统一处理：result 是正序比较结果

            if (sortMode == SortMode.latest) {
              // 时间：默认倒序 (latest first)
              // isAscending = true -> Oldest first (result)
              // isAscending = false -> Newest first (-result)
              return isAscending ? result : -result;
            } else {
              // 名字：默认正序 (A-Z)
              // isAscending = true -> A-Z (result)
              // isAscending = false -> Z-A (-result)
              return isAscending ? result : -result;
            }
          });

        if (filtered.isEmpty) {
          return Center(
            child: Text(
              q.isEmpty ? '暂无角色' : '未找到匹配的角色',
              style: const TextStyle(color: moeMuted, fontSize: 14),
            ),
          );
        }
        // 当前选中的会话，用于高亮联系人卡片（仅在宽屏模式下启用）
        // 窄屏模式下（onContactTap == null）不高亮任何卡片
        final activeId = onContactTap != null
            ? ref.watch(activeConversationIdProvider)
            : null;
        final highlightId = activeId ??
            (onContactTap != null && filtered.isNotEmpty
                ? filtered.first.id
                : null);

        // 移除所有默认边距，确保列表铺满整个容器
        return MediaQuery.removePadding(
          context: context,
          removeTop: true,
          removeBottom: true,
          removeLeft: true,
          removeRight: true,
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              scrollbars: false,
            ),
            child: ListView.builder(
              padding: EdgeInsets.zero, // 确保ListView本身没有padding
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                final c = filtered[index];

                // 预热队列：列表可见时先把头像（以及少量常用会话）提前解码进内存，减少进入聊天页的图片闪烁。
                preheatQueue.enqueueAllFromContext(
                  context,
                  _collectAvatarProviders(c),
                );
                if (index < 6) {
                  preheatQueue.enqueueAllFromContext(
                    context,
                    _collectConversationPreviewProviders(
                      c,
                      maxMessagesToScan: 6,
                      maxImagesToCache: 10,
                    ),
                  );
                }

                return Slidable(
                  key: ValueKey(c.id),
                  endActionPane: ActionPane(
                    motion: const ScrollMotion(),
                    children: [
                      // 置顶/取消置顶
                      SlidableAction(
                        onPressed: (context) async {
                          await ref
                              .read(conversationsProvider.notifier)
                              .updateConversationSettings(
                                c.id,
                                isPinned: !c.isPinned,
                              );
                        },
                        backgroundColor: const Color(0xFF4C5B6F),
                        foregroundColor: Colors.white,
                        icon: c.isPinned
                            ? Icons.push_pin
                            : Icons.push_pin_outlined,
                        label: c.isPinned ? '取消置顶' : '置顶',
                      ),
                      // 删除
                      SlidableAction(
                        onPressed: (context) async {
                          // 显示确认对话框
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('确认删除'),
                              content:
                                  Text('确定要删除 "${c.displayName}" 吗？删除后无法恢复。'),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('取消'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  style: TextButton.styleFrom(
                                    foregroundColor: Colors.red,
                                  ),
                                  child: const Text('删除'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true) {
                            await ref
                                .read(conversationsProvider.notifier)
                                .deleteConversation(c.id);
                          }
                        },
                        backgroundColor: const Color(0xFFFF4D4F),
                        foregroundColor: Colors.white,
                        icon: Icons.delete_outline,
                        label: '删除',
                      ),
                    ],
                  ),
                  child: CharacterListItem(
                    conversation: c,
                    isActive: c.id == highlightId,
                    onTapDown: (_) {
                      preheatQueue.enqueueAllFromContext(
                        context,
                        _collectConversationPreviewProviders(
                          c,
                          // 尽量覆盖聊天页首屏附近的图片，减少“进去后才加载”造成的闪烁。
                          maxMessagesToScan: 30,
                          maxImagesToCache: 24,
                        ),
                        priority: ImagePreheatPriority.high,
                      );
                    },
                    onTap: () {
                      preheatQueue.enqueueAllFromContext(
                        context,
                        _collectConversationPreviewProviders(
                          c,
                          maxMessagesToScan: 30,
                          maxImagesToCache: 24,
                        ),
                        priority: ImagePreheatPriority.high,
                      );

                      if (onContactTap != null) {
                        // 使用自定义回调（宽屏模式）
                        onContactTap!(c.id, ref);
                      } else {
                        // 默认行为：跳转到聊天页面（窄屏模式）
                        ref.read(activeConversationIdProvider.notifier).state =
                            c.id;
                        // 传入初始会话数据，避免新页面首帧先渲染到顶部/错误位置再跳动
                        context.go('/chat/${c.id}', extra: c);
                      }
                    },
                    // 移除 onEdit 参数 - 编辑功能改到聊天界面
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

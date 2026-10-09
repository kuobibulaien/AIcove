import 'dart:async';

import 'package:aicove_flutter/src/ui/theme/moe_interaction_theme.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:aicove_flutter/src/core/utils/image_preheat_queue.dart';
import 'package:aicove_flutter/src/core/utils/avatar_helper.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../../providers2.dart';
import '../../application/chat_page_queries.dart';
import '../../domain/conversation.dart';
import '../../domain/sort_mode.dart';
import 'character_list_item.dart';
import 'privacy_space_pull_detector.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/moe_adaptive_shell.dart';
import '../../../../ui/shared/widgets/moe_scroll_edge.dart';
import '../../../../ui/features/home/pages/privacy_space_page.dart';

@visibleForTesting
VoidCallback scheduleConversationTapWarmup(
  BuildContext context,
  VoidCallback callback, {
  Duration delay = const Duration(milliseconds: 80),
}) {
  var cancelled = false;
  Timer? timer;

  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (cancelled) return;
    timer = Timer(delay, () {
      if (!cancelled) {
        callback();
      }
    });
  });

  return () {
    cancelled = true;
    timer?.cancel();
  };
}

ImageProvider? buildConversationAvatarProvider(Conversation conv) {
  final helper = AvatarHelper(
    avatarUrl: conv.avatarUrl,
    characterImage: conv.characterImage,
    displayName: conv.displayName,
  );
  return helper.getAvatarProvider();
}

/// 联系人列表内容组件 - 纯内容展示，无AppBar（应用DRY原则）
/// 可复用于小屏和大屏布局
class ContactsListContent extends ConsumerStatefulWidget {
  /// 自定义点击回调（可选）
  /// 如果不提供，则使用默认行为（跳转到聊天页面）
  final void Function(String conversationId, WidgetRef ref)? onContactTap;

  final SortMode sortMode;
  final bool isAscending;

  const ContactsListContent({
    super.key,
    this.onContactTap,
    this.sortMode = SortMode.latest,
    this.isAscending = false,
  });

  @override
  ConsumerState<ContactsListContent> createState() =>
      _ContactsListContentState();
}

class _ContactsListContentState extends ConsumerState<ContactsListContent> {
  static const int _kListWarmupConversationCount = 6;

  String _lastWarmupFingerprint = '';
  bool _warmupScheduled = false;
  List<Conversation> _pendingWarmupTargets = const [];

  List<ImageProvider> _collectAvatarProviders(Conversation conv) {
    final images = <ImageProvider>[];
    final avatarProvider = buildConversationAvatarProvider(conv);
    if (avatarProvider != null) {
      images.add(avatarProvider);
    }

    return images;
  }

  void _scheduleVisibleListWarmup(List<Conversation> filtered) {
    // 根联系人页可在聊天转场下继续挂载，不能让它的预读抢当前会话的冷读。
    // 在build中订阅路由状态，返回联系人页后仍有机会开始预读。
    if (ModalRoute.of(context)?.isCurrent == false) return;
    final targets = filtered
        .take(_kListWarmupConversationCount)
        .toList(growable: false);
    if (targets.isEmpty) return;

    final fingerprint = [
      for (final c in targets) '${c.id}:${c.updatedAt.millisecondsSinceEpoch}',
    ].join('|');
    if (fingerprint == _lastWarmupFingerprint) return;

    _lastWarmupFingerprint = fingerprint;
    _pendingWarmupTargets = targets;
    if (_warmupScheduled) return;

    _warmupScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _warmupScheduled = false;
      if (!mounted || _pendingWarmupTargets.isEmpty) return;
      if (ModalRoute.of(context)?.isCurrent == false) {
        _lastWarmupFingerprint = '';
        return;
      }

      unawaited(
        ref
            .read(chatPageQueriesProvider)
            .warmEntryMessages(
              _pendingWarmupTargets.map((conversation) => conversation.id),
            ),
      );
      final queue = ref.read(imagePreheatQueueProvider);
      final configuration = createLocalImageConfiguration(context);
      for (final conv in _pendingWarmupTargets) {
        final avatarProviders = _collectAvatarProviders(conv);
        if (avatarProviders.isNotEmpty) {
          queue.enqueueAll(avatarProviders, configuration);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final listAsync = ref.watch(conversationsProvider);
    return listAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('加载失败: $e')),
      data: (list) {
        // 排序：置顶的在前，然后根据 sortMode 和 isAscending 排序
        final filtered = list.where((c) => !c.isHidden).toList()
          ..sort((a, b) {
            // 1. 置顶优先
            if (a.isPinned != b.isPinned) {
              return a.isPinned ? -1 : 1;
            }

            int result;
            switch (widget.sortMode) {
              case SortMode.name:
                result = a.displayName.compareTo(b.displayName);
              case SortMode.latest:
                result = a.updatedAt.compareTo(b.updatedAt);
            }

            // 如果是最新消息模式，默认是倒序（最新的在上面），所以 isAscending=false 时反转
            // 如果是名字模式，默认是正序（A-Z），所以 isAscending=true 时保持，false 时反转
            // 这里统一处理：result 是正序比较结果

            if (widget.sortMode == SortMode.latest) {
              // 时间：默认倒序 (latest first)
              // isAscending = true -> Oldest first (result)
              // isAscending = false -> Newest first (-result)
              return widget.isAscending ? result : -result;
            } else {
              // 名字：默认正序 (A-Z)
              // isAscending = true -> A-Z (result)
              // isAscending = false -> Z-A (-result)
              return widget.isAscending ? result : -result;
            }
          });

        if (filtered.isNotEmpty) {
          _scheduleVisibleListWarmup(filtered);
        }

        if (filtered.isEmpty) {
          return PrivacySpacePullDetector(
            onTriggered: () => openPrivacySpace(context, ref),
            child: const Center(
              child: Text(
                '暂无角色',
                style: TextStyle(color: moeMuted, fontSize: 14),
              ),
            ),
          );
        }
        // 当前选中的会话，用于高亮联系人卡片（仅在宽屏模式下启用）
        // 窄屏模式下（onContactTap == null）不高亮任何卡片
        final activeId =
            widget.onContactTap != null ||
                (MoeWorkspace.maybeOf(context)?.isWide ?? false)
            ? ref.watch(activeConversationIdProvider)
            : null;
        final highlightId =
            activeId ??
            (widget.onContactTap != null && filtered.isNotEmpty
                ? filtered.first.id
                : null);

        // 列表铺满容器；顶部只保留半透明标题栏让出的距离，内容可从栏下滑过。
        final underBarPadding = moeUnderBarPadding(context);
        return PrivacySpacePullDetector(
          topInset: underBarPadding.top,
          onTriggered: () => openPrivacySpace(context, ref),
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            removeBottom: true,
            removeLeft: true,
            removeRight: true,
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(
                context,
              ).copyWith(scrollbars: false),
              child: ListView.builder(
                padding: underBarPadding,
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final c = filtered[index];
                  return Slidable(
                    key: ValueKey(c.id),
                    endActionPane: ActionPane(
                      motion: const ScrollMotion(),
                      extentRatio: 0.66,
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
                        // 隐藏到隐私空间
                        SlidableAction(
                          // 动作按钮随面板收起而卸载，弹窗链路要用列表自身的 context。
                          onPressed: (_) => hideConversationToPrivacySpace(
                            this.context,
                            ref,
                            c.id,
                          ),
                          backgroundColor: const Color(0xFF7A6FAE),
                          foregroundColor: Colors.white,
                          icon: Icons.visibility_off_outlined,
                          label: '隐藏',
                        ),
                        // 删除
                        SlidableAction(
                          onPressed: (context) async {
                            // 显示确认对话框
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('确认删除'),
                                content: Text(
                                  '确定要删除 "${c.displayName}" 吗？删除后无法恢复。',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, false),
                                    child: const Text('取消'),
                                  ),
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, true),
                                    style: withoutHoverFeedback(
                                      TextButton.styleFrom(
                                        foregroundColor: Colors.red,
                                      ),
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
                      onTap: () {
                        if (widget.onContactTap != null) {
                          // 使用自定义回调（宽屏模式）
                          widget.onContactTap!(c.id, ref);
                        } else {
                          // 默认行为：跳转到聊天页面（窄屏模式）
                          ref
                                  .read(activeConversationIdProvider.notifier)
                                  .state =
                              c.id;
                          // 传入初始会话数据，避免新页面首帧先渲染到顶部/错误位置再跳动
                          MoeWorkspace.openLocation(
                            context,
                            '/chat/${c.id}',
                            extra: c,
                          );
                        }
                      },
                      // 移除 onEdit 参数 - 编辑功能改到聊天界面
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

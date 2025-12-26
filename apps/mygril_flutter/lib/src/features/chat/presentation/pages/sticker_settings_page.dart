import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/expanding_page_route.dart';
import '../../../../core/widgets/moe_toast.dart';
import '../../../../core/widgets/smooth_clip.dart';
import '../../../plugins/plugin_providers.dart';
import '../../../stickers/sticker_registry.dart';

/// 分组方式枚举
enum StickerGroupMode { byTag, byFolder }

/// 表情包设置页面 - 支持按标签/套组两种分组方式
class StickerSettingsPage extends ConsumerStatefulWidget {
  const StickerSettingsPage({super.key});

  @override
  ConsumerState<StickerSettingsPage> createState() => _StickerSettingsPageState();
}

class _StickerSettingsPageState extends ConsumerState<StickerSettingsPage> {
  StickerGroupMode _groupMode = StickerGroupMode.byTag;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final stickerConfig = ref.watch(stickerPluginConfigProvider);
    final registry = StickerRegistry.instance;

    // 根据分组方式获取数据
    final Map<String, List<Sticker>> groupedStickers;
    final List<String> sortedKeys;
    
    if (_groupMode == StickerGroupMode.byTag) {
      groupedStickers = registry.stickersByTag;
      sortedKeys = groupedStickers.keys.toList()..sort();
    } else {
      groupedStickers = registry.stickersByFolder;
      // 文件夹按名称排序
      sortedKeys = groupedStickers.keys.toList()..sort();
    }

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        backgroundColor: colors.surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: colors.text),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          '表情包管理',
          style: TextStyle(color: colors.text, fontSize: 18, fontWeight: FontWeight.w600),
        ),
      ),
      body: Column(
        children: [
          // 开关设置
          _buildEnableToggle(stickerConfig.enabled, colors),
          
          // 分组切换
          _buildGroupModeToggle(colors),
          
          const SizedBox(height: 8),
          
          // 提示文字
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              _groupMode == StickerGroupMode.byTag
                  ? 'AI 使用 [标签] 语法发送表情包，同义词自动匹配。'
                  : '分组可用于管理不同角色的表情包（未来功能）。',
              style: TextStyle(color: colors.muted, fontSize: 13),
            ),
          ),
          
          const SizedBox(height: 12),
          
          // 统计信息
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                _buildStatChip('${registry.stickers.length} 个表情', colors),
                const SizedBox(width: 8),
                _buildStatChip('${registry.allTags.length} 个标签', colors),
                const SizedBox(width: 8),
                _buildStatChip('${registry.allFolders.length} 个分组', colors),
              ],
            ),
          ),
          
          const SizedBox(height: 16),
          
          // 根据分组方式显示不同布局
          Expanded(
            child: _groupMode == StickerGroupMode.byTag
                ? _buildTagListView(sortedKeys, groupedStickers, colors)
                : _buildFolderGridView(sortedKeys, groupedStickers, colors),
          ),
        ],
      ),
    );
  }

  /// 按标签模式 - 列表布局
  Widget _buildTagListView(List<String> sortedKeys, Map<String, List<Sticker>> groupedStickers, MoeColors colors) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: sortedKeys.length,
      itemBuilder: (context, index) {
        final key = sortedKeys[index];
        final stickers = groupedStickers[key] ?? [];
        return _buildTagGroup(key, stickers, colors);
      },
    );
  }

  /// 按分组模式 - iOS相册风格网格布局
  Widget _buildFolderGridView(List<String> sortedKeys, Map<String, List<Sticker>> groupedStickers, MoeColors colors) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,          // 两列
        crossAxisSpacing: 12,       // 列间距
        mainAxisSpacing: 12,        // 行间距
        childAspectRatio: 1,        // 正方形
      ),
      itemCount: sortedKeys.length,
      itemBuilder: (context, index) {
        final folderName = sortedKeys[index];
        final stickers = groupedStickers[folderName] ?? [];
        return _buildFolderCard(folderName, stickers, colors);
      },
    );
  }

  /// 构建文件夹卡片（iOS相册风格）
  /// - 圆角方形
  /// - 图片填充满
  /// - 文字在底部居中悬浮（半透明遮罩）
  Widget _buildFolderCard(String folderName, List<Sticker> stickers, MoeColors colors) {
    final coverSticker = stickers.isNotEmpty ? stickers.first : null;
    const cardRadius = 12.0;
    
    return Builder(
      builder: (cardContext) {
        return GestureDetector(
          onTap: () {
            Navigator.of(context).pushExpanding(
              page: _StickerFolderDetailPage(
                folderName: folderName,
                stickers: stickers,
              ),
              sourceContext: cardContext,
              sourceRadius: cardRadius,
            );
          },
          child: SmoothClipRRect(
            radius: cardRadius,
            child: Container(
              color: colors.surfaceAlt,
              child: Stack(
                fit: StackFit.expand,
                children: [
                // 封面图（填充满）
                coverSticker != null
                    ? Image.asset(
                        coverSticker.assetPath,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _buildPlaceholder(colors),
                      )
                    : _buildPlaceholder(colors),
                // 底部悬浮文字（渐变遮罩）
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(8, 24, 8, 8),
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
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          folderName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${stickers.length} 个表情',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.8),
                            fontSize: 11,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 占位图
  Widget _buildPlaceholder(MoeColors colors) {
    return Center(
      child: Icon(Icons.emoji_emotions_outlined, color: colors.muted, size: 48),
    );
  }

  Widget _buildStatChip(String text, MoeColors colors) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text, style: TextStyle(fontSize: 12, color: colors.muted)),
    );
  }

  /// 构建启用开关
  Widget _buildEnableToggle(bool enabled, MoeColors colors) {
    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
      ),
      child: SwitchListTile(
        title: Text('启用表情包', style: TextStyle(color: colors.text, fontSize: 16, fontWeight: FontWeight.w500)),
        subtitle: Text(enabled ? '已启用' : '已禁用', style: TextStyle(color: enabled ? colors.primary : colors.muted, fontSize: 13)),
        value: enabled,
        activeColor: colors.primary,
        onChanged: (value) => ref.read(stickerPluginConfigProvider.notifier).setEnabled(value),
      ),
    );
  }

  /// 构建分组切换
  Widget _buildGroupModeToggle(MoeColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Text('分组方式：', style: TextStyle(color: colors.text, fontSize: 14)),
          const SizedBox(width: 12),
          Expanded(
            child: SegmentedButton<StickerGroupMode>(
              segments: const [
                ButtonSegment(value: StickerGroupMode.byTag, label: Text('按标签'), icon: Icon(Icons.label_outline, size: 18)),
                ButtonSegment(value: StickerGroupMode.byFolder, label: Text('按分组'), icon: Icon(Icons.folder_outlined, size: 18)),
              ],
              selected: {_groupMode},
              onSelectionChanged: (selection) => setState(() => _groupMode = selection.first),
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 13)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建标签分组（按标签模式使用）
  Widget _buildTagGroup(String tag, List<Sticker> stickers, MoeColors colors) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标签标题
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: colors.primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.label, size: 14, color: colors.primary),
                      const SizedBox(width: 4),
                      Text(
                        '[$tag]',
                        style: TextStyle(color: colors.primary, fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text('${stickers.length}个', style: TextStyle(color: colors.muted, fontSize: 13)),
              ],
            ),
          ),
          // 表情包网格
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: stickers.map((sticker) => _buildStickerItem(sticker, colors)).toList(),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建单个表情包项
  Widget _buildStickerItem(Sticker sticker, MoeColors colors) {
    return Tooltip(
      message: sticker.description.isNotEmpty ? sticker.description : sticker.tags.join(', '),
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          color: colors.surfaceAlt,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.border),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(7),
          child: Image.asset(
            sticker.assetPath,
            width: 64,
            height: 64,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => Center(
              child: Icon(Icons.emoji_emotions, color: colors.muted, size: 32),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// 文件夹详情页 - 展示单个分组内的所有表情包
// ============================================================

class _StickerFolderDetailPage extends StatelessWidget {
  final String folderName;
  final List<Sticker> stickers;

  const _StickerFolderDetailPage({
    required this.folderName,
    required this.stickers,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        backgroundColor: colors.surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: colors.text),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          folderName,
          style: TextStyle(color: colors.text, fontSize: 18, fontWeight: FontWeight.w600),
        ),
        actions: [
          // 未来可添加编辑按钮
          IconButton(
            icon: Icon(Icons.edit_outlined, color: colors.muted),
            onPressed: () {
              // TODO: 实现编辑功能
              MoeToast.brief(context, '编辑功能开发中...');
            },
          ),
        ],
      ),
      body: GridView.builder(
        padding: EdgeInsets.zero,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,       // 四列
          crossAxisSpacing: 1,     // 紧邻，1px间隙
          mainAxisSpacing: 1,      // 紧邻，1px间隙
          childAspectRatio: 1,     // 正方形
        ),
        itemCount: stickers.length,
        itemBuilder: (context, index) {
          final sticker = stickers[index];
          return _buildStickerItem(sticker, colors);
        },
      ),
    );
  }

  Widget _buildStickerItem(Sticker sticker, MoeColors colors) {
    return Tooltip(
      message: sticker.description.isNotEmpty ? sticker.description : sticker.tags.join(', '),
      child: Container(
        color: colors.surfaceAlt,
        child: Image.asset(
          sticker.assetPath,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Center(
            child: Icon(Icons.emoji_emotions, color: colors.muted, size: 32),
          ),
        ),
      ),
    );
  }
}

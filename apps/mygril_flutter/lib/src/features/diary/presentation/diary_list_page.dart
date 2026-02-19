import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/database/database_provider.dart';
import '../../../ui/theme/tokens.dart';
import '../../../ui/shared/effects/smooth_clip.dart';
import '../../../ui/shared/widgets/index.dart';
import '../models/diary_entry.dart';

/// 日记本页面
///
/// 以列表形式展示角色的所有日记，按日期倒序排列
class DiaryListPage extends ConsumerStatefulWidget {
  final String conversationId;
  final String characterName;

  const DiaryListPage({
    super.key,
    required this.conversationId,
    required this.characterName,
  });

  @override
  ConsumerState<DiaryListPage> createState() => _DiaryListPageState();
}

class _DiaryListPageState extends ConsumerState<DiaryListPage> {
  List<DiaryEntry>? _diaries;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadDiaries();
  }

  Future<void> _loadDiaries() async {
    setState(() => _isLoading = true);
    try {
      final repository = ref.read(diaryRepositoryProvider);
      final diaries = await repository.getDiariesByConversation(widget.conversationId);
      setState(() {
        _diaries = diaries;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        backgroundColor: colors.headerColor,
        foregroundColor: colors.headerContentColor,
        elevation: 0,
        title: Text('${widget.characterName}的日记'),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: colors.headerContentColor),
          tooltip: '返回',
          onPressed: () => Navigator.pop(context),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(borderWidth),
          child: Container(height: borderWidth, color: colors.divider),
        ),
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final colors = context.moeColors;

    if (_isLoading) {
      return const Center(child: MoeLoadingIndicator());
    }

    if (_diaries == null || _diaries!.isEmpty) {
      return Center(
        child: MoeEmptyState(
          icon: Icons.book_outlined,
          title: '还没有日记',
          description: '${widget.characterName}还没有写日记哦～\n聊天后会自动生成',
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadDiaries,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _diaries!.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final diary = _diaries![index];
          return _DiaryCard(
            diary: diary,
            onTap: () => _showDiaryDetail(context, diary),
          );
        },
      ),
    );
  }

  void _showDiaryDetail(BuildContext context, DiaryEntry diary) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _DiaryDetailSheet(diary: diary),
    );
  }
}

/// 日记卡片
class _DiaryCard extends StatelessWidget {
  final DiaryEntry diary;
  final VoidCallback? onTap;

  const _DiaryCard({
    required this.diary,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: MoeG2Decoration(
          radius: MoeSmoothRadii.md,
          color: colors.componentBackground,
          border: Border.all(color: colors.borderLight, width: borderWidth),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 日期
            Row(
              children: [
                Icon(Icons.calendar_today, size: 16, color: colors.textSecondary),
                const SizedBox(width: 6),
                Text(
                  diary.formattedDate,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: MoeFontWeights.emphasis,
                    color: colors.textSecondary,
                  ),
                ),
                if (diary.mood != null) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: colors.accent.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      diary.mood!,
                      style: TextStyle(fontSize: 11, color: colors.accent),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            // 内容预览
            Text(
              diary.content,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                height: 1.6,
                color: colors.text,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 日记详情底部弹窗
class _DiaryDetailSheet extends StatelessWidget {
  final DiaryEntry diary;

  const _DiaryDetailSheet({required this.diary});

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final screenHeight = MediaQuery.of(context).size.height;

    return Container(
      constraints: BoxConstraints(maxHeight: screenHeight * 0.8),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 拖动条
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: colors.muted,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // 标题栏
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(
              children: [
                Icon(Icons.calendar_today, size: 18, color: colors.textSecondary),
                const SizedBox(width: 8),
                Text(
                  _formatFullDate(diary.date),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: MoeFontWeights.emphasis,
                    color: colors.text,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.close, color: colors.textSecondary),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: colors.divider),
          // 内容
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Text(
                diary.content,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.8,
                  color: colors.text,
                ),
              ),
            ),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
        ],
      ),
    );
  }

  String _formatFullDate(DateTime date) {
    return '${date.year}年${date.month}月${date.day}日';
  }
}

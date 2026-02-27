import 'package:flutter/material.dart';

import '../../../../core/log_history_service.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/meotalk_dialog.dart';
import '../../../../ui/shared/widgets/moe_toast.dart';
import 'log_history_detail_page.dart';

/// 历史日志列表页面
class LogHistoryListPage extends StatefulWidget {
  const LogHistoryListPage({super.key});

  @override
  State<LogHistoryListPage> createState() => _LogHistoryListPageState();
}

class _LogHistoryListPageState extends State<LogHistoryListPage> {
  List<LogHistoryFile> _files = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    setState(() => _isLoading = true);
    try {
      final files = await LogHistoryService.getHistoryFiles();
      if (mounted) {
        setState(() {
          _files = files;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
        MoeToast.error(context, '加载历史日志失败');
      }
    }
  }

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
          '历史日志',
          style: TextStyle(
            color: colors.text,
            fontSize: 18,
            fontWeight: MoeFontWeights.emphasis,
          ),
        ),
        actions: [
          if (_files.isNotEmpty)
            IconButton(
              tooltip: '清空全部',
              icon: Icon(Icons.delete_sweep, color: colors.text),
              onPressed: _confirmClearAll,
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final colors = context.moeColors;

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_files.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history, size: 48, color: colors.muted),
            const SizedBox(height: 12),
            Text('暂无历史日志', style: TextStyle(color: colors.textSecondary)),
            const SizedBox(height: 8),
            Text(
              '日志会实时自动保存',
              style: TextStyle(color: colors.muted, fontSize: 12),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _files.length,
      itemBuilder: (context, index) => _buildFileItem(_files[index]),
    );
  }

  Widget _buildFileItem(LogHistoryFile file) {
    final colors = context.moeColors;

    IconData typeIcon;
    Color typeColor;
    switch (file.type) {
      case 'app':
        typeIcon = Icons.article_outlined;
        typeColor = Colors.blue;
        break;
      case 'api':
        typeIcon = Icons.api_outlined;
        typeColor = Colors.teal;
        break;
      case 'legacy':
        typeIcon = Icons.history_outlined;
        typeColor = Colors.orange;
        break;
      default:
        typeIcon = Icons.description_outlined;
        typeColor = colors.primary;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: MoeG2Decoration(
        radius: 8,
        color: colors.componentBackground,
        border: Border.all(color: colors.borderLight, width: borderWidth),
      ),
      child: ListTile(
        leading: Icon(typeIcon, color: typeColor),
        title: Text(
          file.formattedTime,
          style: TextStyle(color: colors.text, fontSize: 14),
        ),
        subtitle: Text(
          '${file.typeLabel} · ${file.formattedSize}',
          style: TextStyle(color: colors.textSecondary, fontSize: 12),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon:
                  Icon(Icons.visibility_outlined, color: colors.text, size: 20),
              onPressed: () => _viewFile(file),
              tooltip: '查看',
            ),
            IconButton(
              icon: Icon(Icons.delete_outline, color: colors.muted, size: 20),
              onPressed: () => _deleteFile(file),
              tooltip: '删除',
            ),
          ],
        ),
        onTap: () => _viewFile(file),
      ),
    );
  }

  void _viewFile(LogHistoryFile file) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LogHistoryDetailPage(file: file),
      ),
    );
  }

  Future<void> _deleteFile(LogHistoryFile file) async {
    final confirmed = await showMeoTalkConfirm(
      context: context,
      title: '删除日志',
      message: '确认删除 ${file.formattedTime} 的日志吗？',
      cancelText: '取消',
      confirmText: '删除',
      isDanger: true,
    );
    if (confirmed == true) {
      await LogHistoryService.deleteHistoryFile(file.filePath);
      _loadFiles();
      if (mounted) {
        MoeToast.success(context, '已删除');
      }
    }
  }

  Future<void> _confirmClearAll() async {
    final confirmed = await showMeoTalkConfirm(
      context: context,
      title: '清空历史日志',
      message: '确认清空所有历史日志吗？此操作不可恢复。',
      cancelText: '取消',
      confirmText: '清空',
      isDanger: true,
    );
    if (confirmed == true) {
      final count = await LogHistoryService.clearAllHistory();
      _loadFiles();
      if (mounted) {
        MoeToast.success(context, '已清空 $count 个日志文件');
      }
    }
  }
}

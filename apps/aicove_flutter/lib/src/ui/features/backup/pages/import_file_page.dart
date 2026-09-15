import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:file_picker/file_picker.dart';

import '../../../../features/backup/backup_providers.dart';
import '../../../shared/animations/parallax_slide_page_route.dart';
import '../../../shared/effects/smooth_clip.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import 'import_preview_page.dart';

/// 导入文件选择页面
class ImportFilePage extends ConsumerStatefulWidget {
  const ImportFilePage({super.key});

  @override
  ConsumerState<ImportFilePage> createState() => _ImportFilePageState();
}

class _ImportFilePageState extends ConsumerState<ImportFilePage> {
  bool _isLoading = false;
  String? _errorMessage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return MoePageScaffold(
      appBar: const MoeAppBar(title: '导入数据', showBackButton: true),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 说明
          Text(
            '选择要导入的备份文件',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: MoeFontWeights.emphasis,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '支持 .aicove 格式的备份文件',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),

          const SizedBox(height: 32),

          // 选择文件按钮
          _buildFilePickerCard(context),

          if (_errorMessage != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: MoeG2Decoration(
                radius: 8,
                color: theme.colorScheme.errorContainer,
              ),
              child: Row(
                children: [
                  Icon(
                    LucideIcons.alertCircle,
                    color: theme.colorScheme.error,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 24),

          // 帮助信息
          _buildHelpSection(context),
        ],
      ),
    );
  }

  Widget _buildFilePickerCard(BuildContext context) {
    final theme = Theme.of(context);

    return MoeG2ClipRRect(
      radius: 16,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _isLoading ? null : _pickFile,
          child: MoeButtonSurface(
            padding: const EdgeInsets.all(32),
            radius: 16,
            border: Border.all(
              color: theme.colorScheme.outline.withValues(alpha: 0.3),
              width: 2,
            ),
            child: Column(
              children: [
                if (_isLoading)
                  const MoeLoadingIndicator()
                else
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      LucideIcons.folderOpen,
                      size: 32,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                const SizedBox(height: 16),
                Text(
                  _isLoading ? '正在读取文件...' : '点击选择文件',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: MoeFontWeights.emphasis,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '.aicove',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHelpSection(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: MoeG2Decoration(
        radius: 12,
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                LucideIcons.helpCircle,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '如何获取备份文件？',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: MoeFontWeights.emphasis,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '• 在其他设备上使用"导出数据"功能\n'
            '• 通过微信/QQ/邮件等方式传输文件\n'
            '• 从网盘下载之前保存的备份',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickFile() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) {
        setState(() => _isLoading = false);
        return;
      }

      final filePath = result.files.single.path;
      if (filePath == null) {
        setState(() {
          _isLoading = false;
          _errorMessage = '无法读取文件路径';
        });
        return;
      }

      // 检查文件扩展名
      if (!filePath.toLowerCase().endsWith('.aicove')) {
        setState(() {
          _isLoading = false;
          _errorMessage = '请选择 .aicove 格式的备份文件';
        });
        return;
      }

      final file = File(filePath);
      if (!await file.exists()) {
        setState(() {
          _isLoading = false;
          _errorMessage = '文件不存在';
        });
        return;
      }

      // 预览导入文件
      final importer = ref.read(conversationImporterProvider);
      final preview = await importer.preview(file);

      if (!mounted) return;

      setState(() => _isLoading = false);

      // 跳转到预览页面
      Navigator.of(context).push(
        ParallaxSlidePageRoute(
          page: ImportPreviewPage(file: file, preview: preview),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = '读取文件失败: $e';
      });
    }
  }
}

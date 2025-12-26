import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/utils/message_formatter.dart';
import '../../../settings/app_settings.dart';

/// 分段标点设置页面
class ChunkSettingsPage extends ConsumerStatefulWidget {
  const ChunkSettingsPage({super.key});

  @override
  ConsumerState<ChunkSettingsPage> createState() => _ChunkSettingsPageState();
}

class _ChunkSettingsPageState extends ConsumerState<ChunkSettingsPage> {
  late TextEditingController _chunkPunctuationsCtrl;
  late TextEditingController _filterPunctuationsCtrl;
  MessageFormatConfig? _config;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _chunkPunctuationsCtrl = TextEditingController();
    _filterPunctuationsCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _chunkPunctuationsCtrl.dispose();
    _filterPunctuationsCtrl.dispose();
    super.dispose();
  }

  void _initializeConfig(MessageFormatConfig config) {
    if (!_initialized) {
      _config = config;
      _chunkPunctuationsCtrl.text = config.chunkPunctuations.join('');
      _filterPunctuationsCtrl.text = config.filterPunctuations.join('');
      _initialized = true;
    }
  }

  Future<void> _saveConfig() async {
    if (_config == null) return;
    try {
      final chunkPunctuations = _chunkPunctuationsCtrl.text.split('').where((s) => s.isNotEmpty).toList();
      final filterPunctuations = _filterPunctuationsCtrl.text.split('').where((s) => s.isNotEmpty).toList();

      final newConfig = _config!.copyWith(
        chunkPunctuations: chunkPunctuations.isEmpty ? ['。', '！', '？', '，', '、', '；', '…'] : chunkPunctuations,
        filterPunctuations: filterPunctuations.isEmpty ? ['。', '，', '、', '；', '…', ',', ';'] : filterPunctuations,
      );

      await ref.read(appSettingsProvider.notifier).updateMessageFormatConfig(newConfig);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败: $e'), duration: const Duration(seconds: 1)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final colors = context.moeColors;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: colors.surface,
        foregroundColor: colors.text,
        elevation: 0,
        title: Text('分段设置', style: TextStyle(color: colors.text)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(borderWidth),
          child: Container(color: colors.borderLight, height: borderWidth),
        ),
      ),
      backgroundColor: colors.surface,
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
        data: (settings) {
          _initializeConfig(settings.messageFormatConfig);
          final currentConfig = _config ?? const MessageFormatConfig();

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // ========== 基础设置 ==========
              _buildSectionHeader('基础设置', colors),
              Card(
                color: colors.surfaceAlt,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Column(
                  children: [
                    SwitchListTile(
                      title: const Text('启用消息分段', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                      subtitle: Text('按标点符号自动分段发送', style: TextStyle(fontSize: 13, color: colors.muted)),
                      value: currentConfig.enableChunking,
                      onChanged: (value) async {
                        final newConfig = currentConfig.copyWith(enableChunking: value);
                        setState(() => _config = newConfig);
                        await ref.read(appSettingsProvider.notifier).updateMessageFormatConfig(newConfig);
                      },
                    ),
                    Divider(height: 0, thickness: borderWidth, color: colors.divider),
                    SwitchListTile(
                      title: const Text('过滤句末标点', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                      subtitle: Text('移除分段后末尾的标点符号', style: TextStyle(fontSize: 13, color: colors.muted)),
                      value: currentConfig.filterPunctuation,
                      onChanged: (value) async {
                        final newConfig = currentConfig.copyWith(filterPunctuation: value);
                        setState(() => _config = newConfig);
                        await ref.read(appSettingsProvider.notifier).updateMessageFormatConfig(newConfig);
                      },
                    ),
                  ],
                ),
              ),

              if (currentConfig.enableChunking) ...[
                const SizedBox(height: 24),
                // 分段标点
                _buildSectionHeader('分段标点', colors),
                Card(
                color: colors.surfaceAlt,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('遇到以下标点时分段', style: TextStyle(fontSize: 13, color: colors.muted)),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _chunkPunctuationsCtrl,
                        decoration: InputDecoration(
                          hintText: '例如：。！？，',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: colors.borderLight),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: colors.borderLight),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: colors.primary, width: 2),
                          ),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        ),
                        style: const TextStyle(fontSize: 18, letterSpacing: 4),
                        onChanged: (_) => _saveConfig(),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildPresetChip('默认', '。！？，、；…', _chunkPunctuationsCtrl),
                          _buildPresetChip('精简', '。！？', _chunkPunctuationsCtrl),
                          _buildPresetChip('详细', '。！？，、；：…', _chunkPunctuationsCtrl),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

                // 过滤标点（仅当开启过滤时显示）
                if (currentConfig.filterPunctuation) ...[
                  const SizedBox(height: 24),
                  _buildSectionHeader('过滤标点', colors),
                Card(
                  color: colors.surfaceAlt,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('从分段末尾移除的标点', style: TextStyle(fontSize: 13, color: colors.muted)),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _filterPunctuationsCtrl,
                          decoration: InputDecoration(
                            hintText: '例如：。，',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(color: colors.borderLight),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(color: colors.borderLight),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(color: colors.primary, width: 2),
                            ),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          ),
                          style: const TextStyle(fontSize: 18, letterSpacing: 4),
                          onChanged: (_) => _saveConfig(),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _buildPresetChip('默认', '。，、；…,;', _filterPunctuationsCtrl),
                            _buildPresetChip('保守', '，、,', _filterPunctuationsCtrl),
                            _buildPresetChip('激进', '。！？，、；：…,;', _filterPunctuationsCtrl),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                ],

                // 测试示例
                const SizedBox(height: 24),
                _buildSectionHeader('测试示例', colors),
              Card(
                color: colors.surfaceAlt,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('示例文本：', style: TextStyle(fontSize: 13, color: colors.muted)),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colors.surface,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: colors.borderLight),
                        ),
                        child: const Text(
                          '你好呀！今天天气真不错，我们一起出去玩吧(≧∇≦)/',
                          style: TextStyle(fontSize: 14, height: 1.5),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text('分段结果：', style: TextStyle(fontSize: 13, color: colors.muted)),
                      const SizedBox(height: 8),
                      ...MessageFormatter.formatAndChunkText(
                        '你好呀！今天天气真不错，我们一起出去玩吧(≧∇≦)/',
                        currentConfig,
                      ).asMap().entries.map((entry) {
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: colors.surfaceAlt,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: colors.primary.withOpacity(0.3)),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 24,
                                height: 24,
                                decoration: BoxDecoration(
                                  color: colors.primary,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Center(
                                  child: Text(
                                    '${entry.key + 1}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  entry.value,
                                  style: const TextStyle(fontSize: 14, height: 1.5),
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),
              ], // end of enableChunking condition

              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSectionHeader(String title, MoeColors colors) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: TextStyle(color: colors.textSecondary, fontWeight: FontWeight.w600, fontSize: 13),
      ),
    );
  }

  Widget _buildPresetChip(String label, String punctuations, TextEditingController controller) {
    return ActionChip(
      label: Text(label),
      onPressed: () {
        setState(() {
          controller.text = punctuations;
        });
        _saveConfig();
      },
      backgroundColor: context.moeColors.surface,
      side: BorderSide(color: context.moeColors.borderLight),
    );
  }
}

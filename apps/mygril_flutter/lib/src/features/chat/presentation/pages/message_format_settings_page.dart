import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/utils/message_formatter.dart';
import '../../../settings/app_settings.dart';

/// 消息格式设置页面
class MessageFormatSettingsPage extends ConsumerStatefulWidget {
  const MessageFormatSettingsPage({super.key});

  @override
  ConsumerState<MessageFormatSettingsPage> createState() => _MessageFormatSettingsPageState();
}

class _MessageFormatSettingsPageState extends ConsumerState<MessageFormatSettingsPage> {
  MessageFormatConfig? _config;
  late TextEditingController _chunkPunctuationsCtrl;
  late TextEditingController _filterPunctuationsCtrl;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _chunkPunctuationsCtrl = TextEditingController();
    _filterPunctuationsCtrl = TextEditingController();
  }

  void _initializeConfig(MessageFormatConfig config) {
    if (!_initialized) {
      _config = config;
      _chunkPunctuationsCtrl.text = config.chunkPunctuations.join('');
      _filterPunctuationsCtrl.text = config.filterPunctuations.join('');
      _initialized = true;
    }
  }

  @override
  void dispose() {
    _chunkPunctuationsCtrl.dispose();
    _filterPunctuationsCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveConfig() async {
    // 如果配置还未初始化，不保存
    if (_config == null) return;
    
    try {
      // 解析标点符号列表
      final chunkPunctuations = _chunkPunctuationsCtrl.text.split('').where((s) => s.isNotEmpty).toList();
      final filterPunctuations = _filterPunctuationsCtrl.text.split('').where((s) => s.isNotEmpty).toList();

      final newConfig = _config!.copyWith(
        chunkPunctuations: chunkPunctuations.isEmpty ? ['。', '！', '？', '，', '、', '；', '…'] : chunkPunctuations,
        filterPunctuations: filterPunctuations.isEmpty ? ['。', '，', '、', '；', '…', ',', ';'] : filterPunctuations,
      );

      await ref.read(appSettingsProvider.notifier).updateMessageFormatConfig(newConfig);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('设置已保存'), duration: Duration(seconds: 1)),
        );
      }
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
        title: Text('消息格式设置', style: TextStyle(color: colors.text)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(borderWidth),
          child: Container(
            color: colors.borderLight,
            height: borderWidth,
          ),
        ),
      ),
      backgroundColor: colors.surface,
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
        data: (settings) {
          // 仅在第一次初始化配置
          _initializeConfig(settings.messageFormatConfig);
          
          // 如果 _config 还是 null，使用默认配置
          final currentConfig = _config ?? const MessageFormatConfig();
          
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // 说明卡片
              Card(
                color: colors.surfaceAlt,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.info_outline, color: colors.primary, size: 20),
                          const SizedBox(width: 8),
                          Text(
                            '关于消息分段',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: colors.primary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '开启后将模拟真实聊天，按标点符号自动将长消息拆分成多条发送。颜文字会被自动保护，不会被拆分或过滤。',
                        style: TextStyle(fontSize: 13, height: 1.5),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // 基础设置
              const _SectionHeader(title: '基础设置'),
              Card(
                color: colors.surfaceAlt,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Column(
                  children: [
                    SwitchListTile(
                      title: const Text('启用消息分段', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                      subtitle: Text('按标点符号自动分段发送', style: TextStyle(fontSize: 13, color: colors.muted)),
                      value: currentConfig.enableChunking,
                      onChanged: (value) {
                        setState(() {
                          _config = currentConfig.copyWith(enableChunking: value);
                        });
                        _saveConfig();
                      },
                    ),
                    if (currentConfig.enableChunking) ...[
                      Divider(height: 0, thickness: borderWidth, color: colors.divider),
                      SwitchListTile(
                        title: const Text('过滤末尾标点', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                        subtitle: Text('移除分段后末尾的标点符号', style: TextStyle(fontSize: 13, color: colors.muted)),
                        value: currentConfig.filterPunctuation,
                        onChanged: (value) {
                          setState(() {
                            _config = currentConfig.copyWith(filterPunctuation: value);
                          });
                          _saveConfig();
                        },
                      ),
                    ],
                  ],
                ),
              ),

              if (currentConfig.enableChunking) ...[
                const SizedBox(height: 24),
                const _SectionHeader(title: '分段标点'),
                Card(
                  color: colors.surfaceAlt,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '按以下标点符号分段',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '直接输入标点符号，无需分隔',
                          style: TextStyle(fontSize: 12, color: colors.muted),
                        ),
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
                            _buildPresetChip('默认', '。！？，、；…'),
                            _buildPresetChip('精简', '。！？'),
                            _buildPresetChip('详细', '。！？，、；：…'),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                if (currentConfig.filterPunctuation) ...[
                  const SizedBox(height: 16),
                  const _SectionHeader(title: '过滤标点'),
                  Card(
                    color: colors.surfaceAlt,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '从分段末尾移除的标点',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '直接输入标点符号，无需分隔',
                            style: TextStyle(fontSize: 12, color: colors.muted),
                          ),
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
                              _buildFilterPresetChip('默认', '。，、；…,;'),
                              _buildFilterPresetChip('保守', '，、,'),
                              _buildFilterPresetChip('激进', '。！？，、；：…,;'),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],

                const SizedBox(height: 24),
                const _SectionHeader(title: '测试示例'),
                Card(
                  color: colors.surfaceAlt,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '示例文本：',
                          style: TextStyle(fontSize: 13, color: colors.muted),
                        ),
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
                        Text(
                          '分段结果：',
                          style: TextStyle(fontSize: 13, color: colors.muted),
                        ),
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
                        }).toList(),
                      ],
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPresetChip(String label, String punctuations) {
    return ActionChip(
      label: Text(label),
      onPressed: () {
        setState(() {
          _chunkPunctuationsCtrl.text = punctuations;
        });
        _saveConfig();
      },
      backgroundColor: context.moeColors.surface,
      side: BorderSide(color: context.moeColors.borderLight),
    );
  }

  Widget _buildFilterPresetChip(String label, String punctuations) {
    return ActionChip(
      label: Text(label),
      onPressed: () {
        setState(() {
          _filterPunctuationsCtrl.text = punctuations;
        });
        _saveConfig();
      },
      backgroundColor: context.moeColors.surface,
      side: BorderSide(color: context.moeColors.borderLight),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: TextStyle(
          color: colors.textSecondary,
          fontWeight: FontWeight.w600,
          fontSize: 13,
        ),
      ),
    );
  }
}

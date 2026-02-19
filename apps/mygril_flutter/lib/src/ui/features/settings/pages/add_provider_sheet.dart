/// AddProviderSheet - 添加供应商底部弹窗
///
/// 设计特点：
/// - 底部弹窗形式
/// - 第一步：选择 API 格式（OpenAI/Claude/Gemini）
/// - 第二步：填写基础配置（显示名称、API Key、API 地址）
/// - 第三步：选择模型用途（对话/嵌入/图片/语音，单选）
///
/// 更新记录：
/// - 2026-01-31: 移除TTS用途的二级API格式选择
/// - 2026-01-25: 用途改为多选，一行一个布局
/// - 2026-01-22: 用途改为单选，API格式改为三选一切换框
/// - 2026-01-21: 创建添加供应商底部弹窗
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:figma_squircle/figma_squircle.dart';

import '../../../../features/settings/app_settings.dart';
import '../../../theme/tokens.dart';
import '../../../shared/effects/smooth_clip.dart';
import '../../../shared/widgets/index.dart';

/// 显示添加供应商底部弹窗
Future<bool?> showAddProviderSheet(BuildContext context) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => const AddProviderSheet(),
  );
}

/// API 格式枚举
enum ApiFormat {
  openai('openai', 'OpenAI'),
  claude('claude', 'Claude'),
  gemini('gemini', 'Gemini'),
  novelai('novelai', 'NovelAI');

  const ApiFormat(this.value, this.label);
  final String value;
  final String label;
}

/// 添加供应商底部弹窗
class AddProviderSheet extends ConsumerStatefulWidget {
  const AddProviderSheet({super.key});

  @override
  ConsumerState<AddProviderSheet> createState() => _AddProviderSheetState();
}

class _AddProviderSheetState extends ConsumerState<AddProviderSheet> {
  final _displayCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _urlCtrl = TextEditingController(text: 'https://api.openai.com/v1');

  String _selectedCapability = 'chat';
  ApiFormat _selectedFormat = ApiFormat.openai;
  bool _submitting = false;

  @override
  void dispose() {
    _displayCtrl.dispose();
    _keyCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  void _onFormatChanged(ApiFormat format) {
    setState(() {
      _selectedFormat = format;
      switch (format) {
        case ApiFormat.openai:
          _urlCtrl.text = 'https://api.openai.com/v1';
          break;
        case ApiFormat.claude:
          _urlCtrl.text = 'https://api.anthropic.com/v1';
          break;
        case ApiFormat.gemini:
          _urlCtrl.text = 'https://generativelanguage.googleapis.com/v1beta';
          break;
        case ApiFormat.novelai:
          _urlCtrl.text = 'https://api.novelai.net';
          break;
      }
    });
  }

  Future<void> _submit() async {
    if (_keyCtrl.text.trim().isEmpty) {
      MoeToast.show(context, '请输入 API Key');
      return;
    }
    if (_urlCtrl.text.trim().isEmpty) {
      MoeToast.show(context, '请输入 API 地址');
      return;
    }

    setState(() => _submitting = true);

    try {
      final notifier = ref.read(appSettingsProvider.notifier);
      final isNovelAi = _selectedFormat == ApiFormat.novelai;
      const novelAiModels = <String>[
        'nai-diffusion-4-5-curated-preview',
        'nai-diffusion-4-5-full',
        'nai-diffusion-3',
      ];

      await notifier.importCustomModel(
        name: null,
        apiKey: _keyCtrl.text.trim(),
        apiBaseUrl: _urlCtrl.text.trim(),
        provider: _selectedFormat.value,
        displayName: _displayCtrl.text.trim().isNotEmpty
            ? _displayCtrl.text.trim()
            : null,
        capabilities: [_selectedCapability],
        modelType: _selectedCapability,
        customConfig: {
          'requestFormat': isNovelAi ? 'novelai' : _selectedFormat.value,
        },
        allModels: isNovelAi ? novelAiModels : null,
        visibleModels: isNovelAi ? [novelAiModels.first] : null,
      );
      if (mounted) {
        Navigator.of(context).pop(true);
        MoeToast.show(context, '添加成功');
      }
    } catch (e) {
      if (mounted) {
        MoeToast.show(context, '添加失败: $e', type: ToastType.error);
      }
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final viewInsets = MediaQuery.of(context).viewInsets;
    final screenHeight = MediaQuery.of(context).size.height;

    final sheetBorderRadius = SmoothBorderRadius.vertical(
      top: SmoothRadius(cornerRadius: 24, cornerSmoothing: 0.6),
    );

    // 不把整个 sheet 往上顶：只在内部内容区给键盘让位，观感更像“输入区抬起”。
    return MoeG2ClipRRect.borderRadius(
      borderRadius: sheetBorderRadius,
      child: Container(
        constraints: BoxConstraints(maxHeight: screenHeight * 0.85),
        decoration: MoeG2Decoration.borderRadius(
          borderRadius: sheetBorderRadius,
          color: colors.bgMain,
        ),
        child: SafeArea(
          child: AnimatedPadding(
            duration: kAnimFast,
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.only(bottom: viewInsets.bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 装饰条
                Container(
                  margin: const EdgeInsets.only(top: 12, bottom: 8),
                  width: 32,
                  height: 4,
                  decoration: MoeG2Decoration(
                    radius: 2,
                    color: colors.border.withValues(alpha: 0.5),
                  ),
                ),

                // 标题
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Row(
                    children: [
                      Text(
                        '添加供应商',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: MoeFontWeights.emphasis,
                          color: colors.text,
                        ),
                      ),
                      const Spacer(),
                      MoeIconButton(
                        icon: Icons.close,
                        onTap: () => Navigator.of(context).pop(),
                        backgroundColor: colors.surfaceAlt,
                      ),
                    ],
                  ),
                ),

                const Divider(height: 1),

                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 1. 选择 API 格式
                        _buildSectionTitle('API 格式', colors),
                        const SizedBox(height: 8),
                        MoeSettingsGroup(
                          margin: EdgeInsets.zero,
                          padding: const EdgeInsets.all(12),
                          borderRadius: BorderRadius.circular(20),
                          children: [
                            MoeToggleBar<ApiFormat>(
                              value: _selectedFormat,
                              items: ApiFormat.values
                                  .map((f) =>
                                      MoeToggleItem(value: f, label: f.label))
                                  .toList(),
                              onChanged: _onFormatChanged,
                            ),
                          ],
                        ),

                        const SizedBox(height: 20),

                        // 2. 基础配置
                        _buildSectionTitle('基础配置', colors),
                        const SizedBox(height: 8),
                        MoeSettingsGroup(
                          margin: EdgeInsets.zero,
                          children: [
                            MoeSettingsRow(
                              icon: Icons.badge_outlined,
                              label: '显示名称',
                              trailingType: MoeSettingsRowTrailing.custom,
                              trailing: SizedBox(
                                width: 160,
                                child: TextField(
                                  controller: _displayCtrl,
                                  textAlign: TextAlign.end,
                                  style: TextStyle(
                                      fontSize: 14, color: colors.text),
                                  decoration: InputDecoration(
                                    hintText: '可留空',
                                    hintStyle: TextStyle(
                                        color: colors.muted, fontSize: 14),
                                    border: InputBorder.none,
                                    isDense: true,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                              ),
                            ),
                            MoeSettingsRow(
                              icon: Icons.key_outlined,
                              label: 'API Key',
                              trailingType: MoeSettingsRowTrailing.custom,
                              trailing: SizedBox(
                                width: 160,
                                child: TextField(
                                  controller: _keyCtrl,
                                  obscureText: true,
                                  textAlign: TextAlign.end,
                                  style: TextStyle(
                                      fontSize: 14, color: colors.text),
                                  decoration: InputDecoration(
                                    hintText: '必填',
                                    hintStyle: TextStyle(
                                        color: colors.muted, fontSize: 14),
                                    border: InputBorder.none,
                                    isDense: true,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                              ),
                            ),
                            MoeSettingsRow(
                              icon: Icons.link_outlined,
                              label: 'API 地址',
                              trailingType: MoeSettingsRowTrailing.custom,
                              trailing: SizedBox(
                                width: 180,
                                child: TextField(
                                  controller: _urlCtrl,
                                  textAlign: TextAlign.end,
                                  style: TextStyle(
                                      fontSize: 14, color: colors.text),
                                  decoration: InputDecoration(
                                    hintStyle: TextStyle(
                                        color: colors.muted, fontSize: 14),
                                    border: InputBorder.none,
                                    isDense: true,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 20),

                        // 3. 选择用途（单行4选1，放在底部）
                        _buildSectionTitle('选择用途', colors),
                        const SizedBox(height: 8),
                        _buildCapabilityRow(colors),

                        const SizedBox(height: 24),

                        // 提交按钮
                        Row(
                          children: [
                            Expanded(
                              child: MoeSecondaryButton(
                                label: '取消',
                                onPressed: () => Navigator.of(context).pop(),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: MoePrimaryButton(
                                label: _submitting ? '添加中...' : '立即添加',
                                onPressed: _submitting ? null : _submit,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title, MoeColors colors) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: MoeFontWeights.emphasis,
          color: colors.textSecondary,
        ),
      ),
    );
  }

  /// 单行4选1的用途选择器
  Widget _buildCapabilityRow(MoeColors colors) {
    final capabilities = [
      ModelCapability.chat,
      ModelCapability.embedding,
      ModelCapability.image,
      ModelCapability.tts,
    ];

    return MoeSettingsGroup(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(8),
      children: [
        Row(
          children: capabilities.map((cap) {
            final isSelected = _selectedCapability == cap.value;
            return Expanded(
              child: _buildCapabilityChip(cap, isSelected, colors),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildCapabilityChip(
      ModelCapability cap, bool isSelected, MoeColors colors) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isSelected
        ? cap.color.withValues(alpha: isDark ? 0.25 : 0.15)
        : Colors.transparent;
    final iconColor = isSelected ? cap.color : colors.muted;
    final textColor = isSelected ? cap.color : colors.textSecondary;

    return GestureDetector(
      onTap: () {
        if (_selectedCapability != cap.value) {
          setState(() => _selectedCapability = cap.value);
        }
      },
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: kAnimFast,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: MoeG2Decoration(
          radius: MoeRadii.sm,
          color: bgColor,
          border: isSelected
              ? Border.all(color: cap.color.withValues(alpha: 0.4), width: 1)
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(cap.icon, size: 20, color: iconColor),
            const SizedBox(height: 4),
            Text(
              cap.label,
              style: TextStyle(
                fontSize: 11,
                color: textColor,
                fontWeight: isSelected ? MoeFontWeights.emphasis : MoeFontWeights.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

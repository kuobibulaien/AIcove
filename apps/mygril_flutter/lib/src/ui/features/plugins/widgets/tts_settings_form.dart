/// TtsSettingsForm - TTS 设置表单组件
/// 
/// 从 tts_plugin_detail_page.dart 提取，处理 TTS 配置的各项设置。
/// 
/// 更新记录：
/// - 2025-12-31: 从 tts_plugin_detail_page.dart 提取
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/plugins/plugin_providers.dart';
import '../../../../features/plugins/tts/tts_config.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/index.dart';

/// TTS 设置表单组件
class TtsSettingsForm extends ConsumerStatefulWidget {
  const TtsSettingsForm({super.key});

  @override
  ConsumerState<TtsSettingsForm> createState() => _TtsSettingsFormState();
}

class _TtsSettingsFormState extends ConsumerState<TtsSettingsForm> {
  final _apiKeyController = TextEditingController();
  final _requestUrlController = TextEditingController();
  final _promptAudioUrlController = TextEditingController();
  final _promptTextController = TextEditingController();
  final _speedController = TextEditingController();
  final _maxCharsController = TextEditingController();

  String? _selectedPreset;

  // 内置预设
  static final Map<String, TtsConfig> _presets = {
    'gitee': TtsConfig(
      requestUrl: 'https://ai.gitee.com/v1',
      promptAudioUrl: 'https://github.com/kuobibulaien/astrbot_plugin_reply/raw/refs/heads/master/o74hrkjnaigkrskk8jc2q6c62kgcm4n.wav',
      promptText: '我想了想，要庆祝你的生日，至少也要像「花神诞祭」一样隆重…欸？太夸张了吗？可是我都让人准备好了，走吧走吧，仅限一次也好，绝对会让你满意的！',
      speed: 1.0,
      maxCharsPerChunk: 20,
    ),
    'openai': TtsConfig(
      requestUrl: 'https://api.openai.com/v1/audio/speech',
      speed: 1.0,
      maxCharsPerChunk: 20,
    ),
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadConfig();
    });
  }

  void _loadConfig() {
    final config = ref.read(ttsPluginConfigProvider);
    _apiKeyController.text = config.apiKey ?? '';
    _requestUrlController.text = config.requestUrl;
    _promptAudioUrlController.text = config.promptAudioUrl ?? '';
    _promptTextController.text = config.promptText ?? '';
    _speedController.text = config.speed?.toString() ?? '';
    _maxCharsController.text = config.maxCharsPerChunk.toString();
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _requestUrlController.dispose();
    _promptAudioUrlController.dispose();
    _promptTextController.dispose();
    _speedController.dispose();
    _maxCharsController.dispose();
    super.dispose();
  }

  void _applyPreset(TtsConfig preset, TtsPluginConfigNotifier notifier) {
    // 应用预设配置到输入框
    _requestUrlController.text = preset.requestUrl;
    _promptAudioUrlController.text = preset.promptAudioUrl ?? '';
    _promptTextController.text = preset.promptText ?? '';
    _speedController.text = preset.speed?.toString() ?? '';
    _maxCharsController.text = preset.maxCharsPerChunk.toString();

    // 保存到配置
    notifier.setRequestUrl(preset.requestUrl);
    notifier.setPromptAudio(
      audioUrl: preset.promptAudioUrl,
      text: preset.promptText,
    );
    notifier.setSpeed(preset.speed);
    notifier.setMaxCharsPerChunk(preset.maxCharsPerChunk);

    // 显示提示
    MoeToast.success(context, '已应用预设配置');
  }

  /// 显示预设选择底部弹窗
  void _showPresetSelector() {
    final notifier = ref.read(ttsPluginConfigProvider.notifier);
    
    showMoeActionSheet(
      context: context,
      title: '快速配置',
      description: '选择预设配置自动填充表单',
      actions: [
        MoeSheetAction(
          icon: Icons.tune,
          label: '自定义配置',
          subtitle: '手动填写所有参数',
          onTap: () {
            setState(() => _selectedPreset = null);
          },
        ),
        MoeSheetAction(
          icon: Icons.cloud,
          label: '模力方舟 (Gitee AI)',
          subtitle: '适用于 Gitee AI 平台',
          onTap: () {
            setState(() => _selectedPreset = 'gitee');
            _applyPreset(_presets['gitee']!, notifier);
          },
        ),
        MoeSheetAction(
          icon: Icons.auto_awesome,
          label: 'OpenAI TTS',
          subtitle: '适用于 OpenAI 官方 API',
          onTap: () {
            setState(() => _selectedPreset = 'openai');
            _applyPreset(_presets['openai']!, notifier);
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(ttsPluginConfigProvider);
    final notifier = ref.read(ttsPluginConfigProvider.notifier);
    final colors = context.moeColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 预设选择器
        _buildPresetSelector(colors),
        const SizedBox(height: 16),

        // 设置表单
        _buildSettingsCard(config, notifier, colors),
      ],
    );
  }

  Widget _buildPresetSelector(MoeColors colors) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.panel.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.bookmark_outline, color: colors.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                '快速配置',
                style: TextStyle(
                  color: colors.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          InkWell(
            onTap: _showPresetSelector,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colors.border),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _selectedPreset == null
                          ? '选择预设配置（可选）'
                          : _selectedPreset == 'gitee'
                              ? '模力方舟 (Gitee AI)'
                              : 'OpenAI TTS',
                      style: TextStyle(
                        color: _selectedPreset == null ? colors.muted : colors.text,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  Icon(Icons.arrow_drop_down, color: colors.muted),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsCard(TtsConfig config, TtsPluginConfigNotifier notifier, MoeColors colors) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // API Key
          _buildInputField(
            label: 'API Key',
            hint: '请输入 TTS 服务的 API Key',
            controller: _apiKeyController,
            required: false,
            obscureText: true,
            colors: colors,
            onChanged: (value) {
              notifier.setApiKey(value.isEmpty ? null : value);
            },
          ),
          const SizedBox(height: 16),

          // API URL
          _buildInputField(
            label: 'TTS API URL',
            hint: 'https://your-tts-api.com/synthesize',
            controller: _requestUrlController,
            required: true,
            colors: colors,
            onChanged: (value) {
              notifier.setRequestUrl(value);
            },
          ),
          const SizedBox(height: 16),

          // 参考音频 URL（可选）
          _buildInputField(
            label: '参考音频 URL',
            hint: 'https://example.com/voice-sample.mp3',
            controller: _promptAudioUrlController,
            required: false,
            colors: colors,
            onChanged: (value) {
              notifier.setPromptAudio(
                audioUrl: value.isEmpty ? null : value,
                text: config.promptText,
              );
            },
          ),
          const SizedBox(height: 16),

          // 参考文本（可选）
          _buildInputField(
            label: '参考文本',
            hint: '与参考音频对应的文本',
            controller: _promptTextController,
            required: false,
            maxLines: 2,
            colors: colors,
            onChanged: (value) {
              notifier.setPromptAudio(
                audioUrl: config.promptAudioUrl,
                text: value.isEmpty ? null : value,
              );
            },
          ),
          const SizedBox(height: 16),

          // 语速
          _buildInputField(
            label: '语速 (0.5 ~ 2.0)',
            hint: '1.0',
            controller: _speedController,
            required: false,
            keyboardType: TextInputType.number,
            colors: colors,
            onChanged: (value) {
              final speed = double.tryParse(value);
              notifier.setSpeed(speed);
            },
          ),
          const SizedBox(height: 16),

          // 最大字数
          _buildInputField(
            label: '每段最大字数',
            hint: '20',
            controller: _maxCharsController,
            required: false,
            keyboardType: TextInputType.number,
            colors: colors,
            onChanged: (value) {
              final maxChars = int.tryParse(value);
              if (maxChars != null && maxChars > 0) {
                notifier.setMaxCharsPerChunk(maxChars);
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildInputField({
    required String label,
    required String hint,
    required TextEditingController controller,
    required bool required,
    required MoeColors colors,
    int maxLines = 1,
    bool obscureText = false,
    TextInputType? keyboardType,
    ValueChanged<String>? onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: TextStyle(
                color: colors.text,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (required) ...[
              const SizedBox(width: 4),
              Text(
                '*',
                style: TextStyle(
                  color: colors.accent,
                  fontSize: 14,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          maxLines: maxLines,
          obscureText: obscureText,
          keyboardType: keyboardType,
          onChanged: onChanged,
          style: TextStyle(
            color: colors.text,
            fontSize: 14,
          ),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
              color: colors.muted,
              fontSize: 14,
            ),
            filled: true,
            fillColor: colors.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: colors.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: colors.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: colors.primary, width: 2),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
          ),
        ),
      ],
    );
  }
}

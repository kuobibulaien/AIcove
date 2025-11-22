import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/models/message_block.dart';
import '../../../plugins/plugin_providers.dart';
import '../../../plugins/tts/tts_config.dart';
import '../../../plugins/tts/tts_service.dart';
import '../widgets/audio_player_widget.dart';

/// TTS 插件详细设置页面
class TtsPluginDetailPage extends ConsumerStatefulWidget {
  const TtsPluginDetailPage({super.key});

  @override
  ConsumerState<TtsPluginDetailPage> createState() => _TtsPluginDetailPageState();
}

enum TestStatus { idle, testing, success, error }

class _TtsPluginDetailPageState extends ConsumerState<TtsPluginDetailPage> {
  final _apiKeyController = TextEditingController();
  final _requestUrlController = TextEditingController();
  final _promptAudioUrlController = TextEditingController();
  final _promptTextController = TextEditingController();
  final _speedController = TextEditingController();
  final _maxCharsController = TextEditingController();
  final _testTextController = TextEditingController(text: '你好，这是一段测试文本。');

  String? _selectedPreset;
  TestStatus _testStatus = TestStatus.idle;
  String? _testError;
  String? _testAudioUrl;

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
    _testTextController.dispose();
    super.dispose();
  }

  /// 测试 TTS 转换功能
  Future<void> _testTtsConversion() async {
    final testText = _testTextController.text.trim();
    if (testText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('请输入测试文本'),
          backgroundColor: moeAccent,
        ),
      );
      return;
    }

    setState(() {
      _testStatus = TestStatus.testing;
      _testError = null;
      _testAudioUrl = null;
    });

    try {
      // 使用当前配置创建 TTS 服务
      final config = ref.read(ttsPluginConfigProvider);
      final service = TtsService(config);

      // 调用转换
      final result = await service.convert(testText);

      if (result.success && result.audioUrl.isNotEmpty) {
        setState(() {
          _testStatus = TestStatus.success;
          _testAudioUrl = result.audioUrl;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('测试成功！音频已生成'),
            backgroundColor: moePrimary,
          ),
        );
      } else {
        setState(() {
          _testStatus = TestStatus.error;
          _testError = result.error ?? '转换失败，未知错误';
        });
      }
    } on TtsException catch (e) {
      setState(() {
        _testStatus = TestStatus.error;
        _testError = e.message;
      });
    } catch (e) {
      setState(() {
        _testStatus = TestStatus.error;
        _testError = '测试失败: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(ttsPluginConfigProvider);
    final notifier = ref.read(ttsPluginConfigProvider.notifier);

    return Scaffold(
      backgroundColor: moeSurface,
      appBar: AppBar(
        backgroundColor: moeSurface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: moeText),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          '语音合成 (TTS)',
          style: TextStyle(
            color: moeText,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 启用开关
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: moePanel,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: moeBorder),
              ),
              child: Row(
                children: [
                  Text(
                    '启用插件',
                    style: TextStyle(
                      color: moeText,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Switch(
                    value: config.enabled,
                    onChanged: (value) async {
                      await notifier.setEnabled(value);
                    },
                    activeColor: moePrimary,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // 设置表单
            if (config.enabled) ...[
              Text(
                '详细设置',
                style: TextStyle(
                  color: moeText,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              _buildPresetSelector(notifier),
              const SizedBox(height: 16),
              _buildTtsSettings(config, notifier),
              const SizedBox(height: 24),

              // 测试功能
              _buildTestSection(),
              const SizedBox(height: 24),
            ],

            // 使用说明
            _buildHelpSection(),
          ],
        ),
      ),
    );
  }

  Widget _buildPresetSelector(TtsPluginConfigNotifier notifier) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: moePanel.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: moeBorder.withOpacity(0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.bookmark_outline, color: moePrimary, size: 20),
              const SizedBox(width: 8),
              Text(
                '快速配置',
                style: TextStyle(
                  color: moeText,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _selectedPreset,
            decoration: InputDecoration(
              hintText: '选择预设配置（可选）',
              hintStyle: TextStyle(color: moeMuted, fontSize: 14),
              filled: true,
              fillColor: moeSurface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: moeBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: moeBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: moePrimary, width: 2),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            items: [
              DropdownMenuItem<String>(
                value: null,
                child: Text('自定义配置', style: TextStyle(color: moeText, fontSize: 14)),
              ),
              DropdownMenuItem<String>(
                value: 'gitee',
                child: Text('模力方舟 (Gitee AI)', style: TextStyle(color: moeText, fontSize: 14)),
              ),
              DropdownMenuItem<String>(
                value: 'openai',
                child: Text('OpenAI TTS', style: TextStyle(color: moeText, fontSize: 14)),
              ),
            ],
            onChanged: (value) {
              setState(() {
                _selectedPreset = value;
              });
              if (value != null && _presets.containsKey(value)) {
                final preset = _presets[value]!;
                _applyPreset(preset, notifier);
              }
            },
          ),
        ],
      ),
    );
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已应用预设配置'),
        duration: const Duration(seconds: 1),
        backgroundColor: moePrimary,
      ),
    );
  }

  Widget _buildTtsSettings(TtsConfig config, TtsPluginConfigNotifier notifier) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: moePanel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: moeBorder),
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
                color: moeText,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (required) ...[
              const SizedBox(width: 4),
              Text(
                '*',
                style: TextStyle(
                  color: moeAccent,
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
            color: moeText,
            fontSize: 14,
          ),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
              color: moeMuted,
              fontSize: 14,
            ),
            filled: true,
            fillColor: moeSurface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: moeBorder),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: moeBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: moePrimary, width: 2),
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

  Widget _buildTestSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: moePanel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: moeBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.play_circle_outline, color: moePrimary, size: 20),
              const SizedBox(width: 8),
              Text(
                '测试功能',
                style: TextStyle(
                  color: moeText,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // 测试文本输入
          Text(
            '测试文本',
            style: TextStyle(
              color: moeText,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _testTextController,
            maxLines: 3,
            style: TextStyle(
              color: moeText,
              fontSize: 14,
            ),
            decoration: InputDecoration(
              hintText: '输入要测试转换的文本...',
              hintStyle: TextStyle(
                color: moeMuted,
                fontSize: 14,
              ),
              filled: true,
              fillColor: moeSurface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: moeBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: moeBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: moePrimary, width: 2),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 测试按钮
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _testStatus == TestStatus.testing ? null : _testTtsConversion,
              icon: _testStatus == TestStatus.testing
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : Icon(Icons.play_arrow),
              label: Text(
                _testStatus == TestStatus.testing ? '测试中...' : '开始测试',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: moePrimary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                elevation: 0,
              ),
            ),
          ),

          // 测试结果显示
          if (_testStatus == TestStatus.success && _testAudioUrl != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: moePrimary.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: moePrimary.withOpacity(0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.check_circle, color: moePrimary, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        '测试成功',
                        style: TextStyle(
                          color: moePrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  AudioPlayerWidget(
                    block: AudioBlock(
                      messageId: 'tts-test',
                      url: _testAudioUrl!,
                      text: _testTextController.text,
                    ),
                    textColor: moeText,
                  ),
                ],
              ),
            ),
          ],

          if (_testStatus == TestStatus.error && _testError != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: moeAccent.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: moeAccent.withOpacity(0.3)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline, color: moeAccent, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '测试失败',
                          style: TextStyle(
                            color: moeAccent,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _testError!,
                          style: TextStyle(
                            color: moeTextSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHelpSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: moePanel.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: moeBorder.withOpacity(0.5),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.help_outline, color: moePrimary, size: 20),
              SizedBox(width: 8),
              Text(
                '使用说明',
                style: TextStyle(
                  color: moeText,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '启用 TTS 插件后，AI 会自动使用 <tts>文本</tts> 标记需要转换为语音的内容。\n\n'
            '标记规则：\n'
            '• 每个 <tts></tts> 标记内的文本不超过设定的字数限制\n'
            '• 超过限制的文本会自动拆分成多段\n'
            '• 一轮对话可以使用多个 <tts></tts> 标记\n'
            '• 语音会按顺序自动转换和播放',
            style: TextStyle(
              color: moeTextSecondary,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

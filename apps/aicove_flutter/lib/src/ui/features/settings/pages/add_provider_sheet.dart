/// AddProviderSheet - 添加供应商底部弹窗
///
/// 设计特点：
/// - 第一行选择供应商分类：对话 / 绘图 / 语音
/// - 第二行按分类切换 API 格式（ComfyUI、NovelAI 只属于绘图）
/// - 基础配置输入框占满标题以外的宽度
/// - 绘图／语音供应商导入时整体定型为对应分类
///
/// 更新记录：
/// - 2026-10-04: 重写；新增分类选择，ComfyUI 移出对话格式，输入框自适应宽度
/// - 2026-02-21: NovelAI 移入内置供应商列表
/// - 2026-01-21: 创建添加供应商底部弹窗
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/api/image_providers/comfyui_image_adapter.dart';
import '../../../../core/api/image_providers/comfyui_workflow.dart';
import '../../../../core/api/providers/google_api_mode.dart';
import '../../../../core/api/providers/provider_chat_api_path.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../features/settings/data/support/ui_models_store_support.dart'
    show kNovelAiDefaultModels;
import '../../../shared/effects/smooth_clip.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import '../widgets/comfyui_workflow_editor.dart';

/// 显示添加供应商底部弹窗
Future<bool?> showAddProviderSheet(BuildContext context) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => const AddProviderSheet(),
  );
}

/// 供应商分类，值与 provider capabilities 一致
enum ProviderCategory {
  chat('chat', '对话'),
  image('image', '绘图'),
  tts('tts', '语音');

  const ProviderCategory(this.value, this.label);

  final String value;
  final String label;
}

/// API 格式
class ApiFormat {
  const ApiFormat._({
    required this.value,
    required this.label,
    required this.defaultBaseUrl,
    String? providerId,
    this.defaultApiPath = '',
    this.defaultModels = const <String>[],
    this.apiKeyOptional = false,
  }) : providerId = providerId ?? value;

  /// 写入 customConfig.requestFormat 的值
  final String value;
  final String label;
  final String defaultBaseUrl;

  /// 导入时的渠道 id 前缀（重名时自动追加序号）
  final String providerId;

  /// 对话请求路径；为空表示该格式不需要填写路径
  final String defaultApiPath;

  /// 拉取不到对应分类模型时使用的默认模型
  final List<String> defaultModels;
  final bool apiKeyOptional;

  bool get showsApiPath => defaultApiPath.isNotEmpty;

  static const openai = ApiFormat._(
    value: 'openai',
    label: 'OpenAI',
    defaultBaseUrl: 'https://api.openai.com/v1',
    defaultApiPath: '/chat/completions',
  );
  static const claude = ApiFormat._(
    value: 'claude',
    label: 'Claude',
    defaultBaseUrl: 'https://api.anthropic.com/v1',
    defaultApiPath: '/messages',
  );
  static const gemini = ApiFormat._(
    value: 'gemini',
    label: 'Gemini',
    defaultBaseUrl: kGeminiDeveloperApiBase,
    defaultApiPath: '/models/{model}:generateContent',
  );

  static const openaiImage = ApiFormat._(
    value: 'openai',
    label: 'OpenAI',
    defaultBaseUrl: 'https://api.openai.com/v1',
    defaultModels: <String>['gpt-image-1'],
  );
  static const novelai = ApiFormat._(
    value: 'novelai',
    label: 'NovelAI',
    defaultBaseUrl: 'https://image.novelai.net',
    defaultModels: kNovelAiDefaultModels,
  );
  static const comfyui = ApiFormat._(
    value: 'comfyui',
    label: 'ComfyUI',
    defaultBaseUrl: 'http://127.0.0.1:8188',
    apiKeyOptional: true,
  );

  static const openaiTts = ApiFormat._(
    value: 'openai_tts',
    providerId: 'openai',
    label: 'OpenAI',
    defaultBaseUrl: 'https://api.openai.com/v1',
    defaultModels: <String>['gpt-4o-mini-tts', 'tts-1', 'tts-1-hd'],
  );
  static const minimaxTts = ApiFormat._(
    value: 'minimax',
    label: 'MiniMax',
    defaultBaseUrl: 'https://api.minimaxi.com/v1',
    defaultModels: <String>['speech-2.8-hd', 'speech-2.8-turbo'],
  );
  static const siliconflowTts = ApiFormat._(
    value: 'siliconflow_indextts',
    providerId: 'siliconflow',
    label: '硅基流动',
    defaultBaseUrl: 'https://api.siliconflow.cn/v1',
    defaultModels: <String>[
      'IndexTeam/IndexTTS-2',
      'FunAudioLLM/CosyVoice2-0.5B',
    ],
  );
  // 阿里云按模型名区分 CosyVoice / Qwen-TTS，requestFormat 留默认交给 URL 识别。
  static const aliyunTts = ApiFormat._(
    value: 'openai_tts',
    providerId: 'aliyun',
    label: '阿里云',
    defaultBaseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    defaultModels: <String>[
      'cosyvoice-v3-plus',
      'qwen3-tts-vc-realtime-2026-01-15',
    ],
  );
  static const fishAudioTts = ApiFormat._(
    value: 'fish_audio',
    label: 'Fish Audio',
    defaultBaseUrl: 'https://api.fish.audio/v1',
    defaultModels: <String>['s2.1-pro-free', 's2.1-pro'],
  );

  static const chatFormats = <ApiFormat>[openai, claude, gemini];
  static const imageFormats = <ApiFormat>[openaiImage, novelai, comfyui];
  static const ttsFormats = <ApiFormat>[
    openaiTts,
    minimaxTts,
    siliconflowTts,
    aliyunTts,
    fishAudioTts,
  ];

  static List<ApiFormat> forCategory(ProviderCategory category) {
    return switch (category) {
      ProviderCategory.chat => chatFormats,
      ProviderCategory.image => imageFormats,
      ProviderCategory.tts => ttsFormats,
    };
  }
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
  final _urlCtrl = TextEditingController(text: ApiFormat.openai.defaultBaseUrl);
  final _pathCtrl = TextEditingController(
    text: ApiFormat.openai.defaultApiPath,
  );

  ProviderCategory _category = ProviderCategory.chat;
  ApiFormat _selectedFormat = ApiFormat.openai;
  bool _submitting = false;
  Map<String, dynamic> _comfyConfig = {};
  bool get _isComfyUI => _selectedFormat == ApiFormat.comfyui;

  @override
  void dispose() {
    _displayCtrl.dispose();
    _keyCtrl.dispose();
    _urlCtrl.dispose();
    _pathCtrl.dispose();
    super.dispose();
  }

  void _onCategoryChanged(ProviderCategory category) {
    _category = category;
    _onFormatChanged(ApiFormat.forCategory(category).first);
  }

  void _onFormatChanged(ApiFormat format) {
    setState(() {
      _selectedFormat = format;
      _urlCtrl.text = format.defaultBaseUrl;
      _pathCtrl.text = format.defaultApiPath;
    });
  }

  List<String> _pickDefaultVisibleModels(List<String> models) {
    if (_category != ProviderCategory.chat) {
      return models.take(3).toList();
    }
    final selected = <String>[];
    final pickedTypes = <ModelType>{};
    for (final model in models) {
      final type = ModelType.inferFromModelId(model);
      if (pickedTypes.add(type)) {
        selected.add(model);
      }
    }
    if (selected.isEmpty && models.isNotEmpty) {
      selected.add(models.first);
    }
    return selected;
  }

  /// 绘图／语音只保留对应分类的模型，ComfyUI 的工作流模型不按名字过滤。
  List<String> _filterByCategory(List<String> models) {
    if (_category == ProviderCategory.chat || _isComfyUI) return models;
    return models
        .where(
          (model) => ModelType.inferFromModelId(model).value == _category.value,
        )
        .toList();
  }

  Future<void> _submit() async {
    final format = _selectedFormat;
    final apiKey = _keyCtrl.text.trim();
    final apiBaseUrl = _urlCtrl.text.trim();
    final apiPath = format.showsApiPath ? _pathCtrl.text.trim() : '';
    final displayName = _displayCtrl.text.trim();

    if (apiKey.isEmpty && !format.apiKeyOptional) {
      MoeToast.show(context, '请输入 API Key');
      return;
    }
    if (apiBaseUrl.isEmpty) {
      MoeToast.show(context, '请输入 API 地址');
      return;
    }
    if (apiPath.isEmpty && format.showsApiPath) {
      MoeToast.show(context, '请输入 API 路径');
      return;
    }

    if (_isComfyUI) {
      try {
        ComfyUIImageAdapter.endpoint(apiBaseUrl, 'prompt');
        ComfyUIWorkflow.validate(_comfyConfig);
      } catch (error) {
        MoeToast.show(context, error.toString(), type: ToastType.error);
        return;
      }
    }
    setState(() => _submitting = true);

    try {
      final notifier = ref.read(appSettingsProvider.notifier);
      var previewFailed = false;
      var allModels = const <String>[];
      final customConfig = copyCustomConfigWithProviderChatApiPath(
        <String, dynamic>{
          'requestFormat': format.value,
          if (_isComfyUI) ..._comfyConfig,
        },
        apiPath,
      );

      try {
        allModels = _filterByCategory(
          await notifier.previewProviderModels(
            providerId: format.providerId,
            apiKey: apiKey,
            apiBaseUrl: apiBaseUrl,
            customConfig: customConfig,
          ),
        );
      } catch (_) {
        previewFailed = true;
      }
      if (allModels.isEmpty && format.defaultModels.isNotEmpty) {
        allModels = List<String>.of(format.defaultModels);
        previewFailed = false;
      }

      await notifier.importCustomModel(
        name: null,
        apiKey: apiKey,
        apiBaseUrl: apiBaseUrl,
        provider: format.providerId,
        displayName: displayName.isNotEmpty ? displayName : null,
        allModels: allModels,
        visibleModels: _pickDefaultVisibleModels(allModels),
        customConfig: customConfig,
        capabilities: <String>[_category.value],
      );

      if (!mounted) return;
      Navigator.of(context).pop(true);
      if (previewFailed) {
        MoeToast.show(
          context,
          '无法连接到模型服务，已先保存渠道。请检查 API 地址或 Key，可在详情页刷新模型列表。',
          type: ToastType.warning,
        );
      } else {
        MoeToast.show(context, '添加成功');
      }
    } catch (e) {
      if (mounted) {
        MoeToast.show(
          context,
          _buildSubmitErrorMessage(e),
          type: ToastType.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  String _buildSubmitErrorMessage(Object error) {
    final raw = error.toString();
    if (raw.contains('provider_id') && raw.contains('api_key')) {
      return '添加失败：API Key 不能为空';
    }
    return '添加失败：$raw';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final viewInsets = MediaQuery.of(context).viewInsets;
    final screenHeight = MediaQuery.of(context).size.height;

    // 不把整个 sheet 往上顶：只在内部内容区给键盘让位。
    return MoeFloatingSurface(
      baseline: MoeMaterialBaseline.background,
      radius: 24,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: Container(
        constraints: BoxConstraints(maxHeight: screenHeight * 0.85),
        child: SafeArea(
          child: AnimatedPadding(
            duration: kAnimFast,
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.only(bottom: viewInsets.bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 12, bottom: 8),
                  width: 32,
                  height: 4,
                  decoration: MoeG2Decoration(
                    radius: 2,
                    color: colors.border.withValues(alpha: 0.5),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
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
                        _buildSectionTitle('类型与格式', colors),
                        const SizedBox(height: 8),
                        MoeSettingsGroup(
                          margin: EdgeInsets.zero,
                          padding: const EdgeInsets.all(12),
                          borderRadius: BorderRadius.circular(20),
                          children: [
                            MoeToggleBar<ProviderCategory>(
                              value: _category,
                              items: ProviderCategory.values
                                  .map(
                                    (c) =>
                                        MoeToggleItem(value: c, label: c.label),
                                  )
                                  .toList(),
                              onChanged: _onCategoryChanged,
                            ),
                            const SizedBox(height: 10),
                            _FormatBar(
                              value: _selectedFormat,
                              formats: ApiFormat.forCategory(_category),
                              onChanged: _onFormatChanged,
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        _buildSectionTitle('基础配置', colors),
                        const SizedBox(height: 8),
                        MoeSettingsGroup(
                          margin: EdgeInsets.zero,
                          children: [
                            _buildInputRow(
                              colors,
                              icon: Icons.badge_outlined,
                              label: '显示名称',
                              controller: _displayCtrl,
                              hintText: '可留空',
                            ),
                            _buildInputRow(
                              colors,
                              icon: Icons.key_outlined,
                              label: 'API Key',
                              controller: _keyCtrl,
                              hintText: _selectedFormat.apiKeyOptional
                                  ? '可选（Bearer Token）'
                                  : '必填',
                            ),
                            _buildInputRow(
                              colors,
                              icon: Icons.link_outlined,
                              label: '基础 URL',
                              controller: _urlCtrl,
                              showDivider: _selectedFormat.showsApiPath,
                            ),
                            if (_selectedFormat.showsApiPath)
                              _buildInputRow(
                                colors,
                                icon: Icons.route_outlined,
                                label: 'API 路径',
                                controller: _pathCtrl,
                                showDivider: false,
                              ),
                          ],
                        ),
                        if (_isComfyUI) ...[
                          const SizedBox(height: 16),
                          MoeSettingsGroup(
                            margin: EdgeInsets.zero,
                            children: [
                              MoeSettingsRow(
                                label: 'ComfyUI 工作流',
                                detailText: _comfyConfig.isEmpty
                                    ? '导入并绑定提示词'
                                    : '已配置',
                                trailingType: MoeSettingsRowTrailing.text,
                                showDivider: false,
                                onTap: () async {
                                  final config =
                                      await showComfyUIWorkflowEditor(
                                        context,
                                        _comfyConfig,
                                      );
                                  if (config != null && mounted) {
                                    setState(() => _comfyConfig = config);
                                  }
                                },
                              ),
                            ],
                          ),
                          _buildHint(
                            '同机可用 127.0.0.1；手机连接电脑时填写电脑的局域网地址。模型与 LoRA 由工作流指定。',
                            colors,
                          ),
                        ],
                        ValueListenableBuilder<TextEditingValue>(
                          valueListenable: _urlCtrl,
                          builder: (context, value, _) {
                            if (_selectedFormat != ApiFormat.openai ||
                                !shouldSuggestOpenAiBaseUrlV1(value.text)) {
                              return const SizedBox.shrink();
                            }
                            return _buildHint(
                              'OpenAI 格式推荐让基础 URL 以 /v1 结尾，模型预览会更稳。',
                              colors,
                            );
                          },
                        ),
                        const SizedBox(height: 32),
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

  /// 输入框占满标题右侧的全部空间，长 URL 也能尽量完整显示。
  Widget _buildInputRow(
    MoeColors colors, {
    required IconData icon,
    required String label,
    required TextEditingController controller,
    String? hintText,
    bool showDivider = true,
  }) {
    return MoeSettingsRow(
      icon: icon,
      label: label,
      showDivider: showDivider,
      trailingType: MoeSettingsRowTrailing.custom,
      expandTrailing: true,
      trailing: TextField(
        controller: controller,
        textAlign: TextAlign.end,
        style: TextStyle(fontSize: 14, color: colors.text),
        decoration: MoeInputDecoration(
          hintText: hintText,
          hintStyle: TextStyle(color: colors.muted, fontSize: 14),
          isDense: true,
          contentPadding: EdgeInsets.zero,
        ),
      ),
    );
  }

  Widget _buildHint(String text, MoeColors colors) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: MoeG2Decoration(
          radius: MoeRadii.md,
          color: colors.surfaceAlt.withValues(alpha: 0.72),
          border: Border.all(
            color: colors.border.withValues(alpha: 0.45),
            width: 1,
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            color: colors.textSecondary,
            height: 1.35,
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
}

/// API 格式切换条：放得下时等分撑满，放不下时改为横向滚动。
class _FormatBar extends StatelessWidget {
  const _FormatBar({
    required this.value,
    required this.formats,
    required this.onChanged,
  });

  static const double _minItemWidth = 84;

  final ApiFormat value;
  final List<ApiFormat> formats;
  final ValueChanged<ApiFormat> onChanged;

  @override
  Widget build(BuildContext context) {
    final items = formats
        .map((f) => MoeToggleItem(value: f, label: f.label))
        .toList();
    return LayoutBuilder(
      builder: (context, constraints) {
        final fits = constraints.maxWidth / formats.length >= _minItemWidth;
        final bar = MoeToggleBar<ApiFormat>(
          value: value,
          items: items,
          expanded: fits,
          onChanged: onChanged,
        );
        if (fits) return bar;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: bar,
        );
      },
    );
  }
}

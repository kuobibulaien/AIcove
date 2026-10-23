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
import '../../../../core/api/providers/google_api_mode.dart';
import '../../../../core/api/providers/provider_chat_api_path.dart';
import '../../../../features/plugins/tts/tts_request_format.dart';
import '../../../../features/voice_call/domain/asr_request_format.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../features/settings/data/support/ui_models_store_support.dart'
    show kNovelAiDefaultModels;
import '../../../shared/effects/smooth_clip.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import '../widgets/tts_request_template_editor.dart';

/// 显示添加供应商底部弹窗
Future<bool?> showAddProviderSheet(
  BuildContext context, {
  ProviderCategory initialCategory = ProviderCategory.chat,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => AddProviderSheet(initialCategory: initialCategory),
  );
}

/// 供应商分类，值与 provider capabilities 一致
enum ProviderCategory {
  chat('chat', '对话'),
  image('image', '绘图'),
  tts('tts', '语音'),
  stt('stt', '识别');

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
    this.asr,
  }) : providerId = providerId ?? value;

  /// 语音识别格式；写入 customConfig.asrRequestFormat 而不是 requestFormat。
  final AsrRequestFormat? asr;

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

  /// 语音格式统一取自 [TtsRequestFormat] 注册表。
  static final ttsFormats = TtsRequestFormat.all
      .map(
        (format) => ApiFormat._(
          value: format.value,
          label: format.label,
          defaultBaseUrl: format.defaultBaseUrl,
          providerId: format.providerId,
          defaultModels: format.defaultModels,
        ),
      )
      .toList(growable: false);

  /// 识别格式统一取自 [AsrRequestFormat] 注册表。
  static final asrFormats = AsrRequestFormat.all
      .map(
        (format) => ApiFormat._(
          value: format.value,
          label: format.label,
          defaultBaseUrl: format.defaultEndpoint,
          providerId: format.providerId,
          defaultModels: format.defaultModels,
          asr: format,
        ),
      )
      .toList(growable: false);

  static const chatFormats = <ApiFormat>[openai, claude, gemini];
  static const imageFormats = <ApiFormat>[openaiImage, novelai, comfyui];

  static List<ApiFormat> forCategory(ProviderCategory category) {
    return switch (category) {
      ProviderCategory.chat => chatFormats,
      ProviderCategory.image => imageFormats,
      ProviderCategory.tts => ttsFormats,
      ProviderCategory.stt => asrFormats,
    };
  }
}

/// 添加供应商底部弹窗
class AddProviderSheet extends ConsumerStatefulWidget {
  const AddProviderSheet({
    super.key,
    this.initialCategory = ProviderCategory.chat,
  });

  final ProviderCategory initialCategory;

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
  bool get _isComfyUI => _selectedFormat == ApiFormat.comfyui;
  Map<String, dynamic> _ttsTemplate = Map<String, dynamic>.of(
    TtsRequestFormat.defaultCustomRestTemplate,
  );
  bool get _isCustomRestTts =>
      _category == ProviderCategory.tts &&
      _selectedFormat.value == TtsRequestFormat.customRest.value;

  /// 识别格式除 API Key 外的凭证（AppID、SecretId 等），按 [AsrCredentialField.key]。
  final _credentialCtrls = <String, TextEditingController>{};

  TextEditingController _credentialCtrl(String key) =>
      _credentialCtrls.putIfAbsent(key, TextEditingController.new);

  @override
  void initState() {
    super.initState();
    if (widget.initialCategory != ProviderCategory.chat) {
      _category = widget.initialCategory;
      final format = ApiFormat.forCategory(_category).first;
      _selectedFormat = format;
      _urlCtrl.text = format.defaultBaseUrl;
      _pathCtrl.text = format.defaultApiPath;
    }
  }

  @override
  void dispose() {
    for (final ctrl in _credentialCtrls.values) {
      ctrl.dispose();
    }
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

    final asr = format.asr;
    final credentials = <String, String>{};
    for (final field in asr?.credentialFields ?? const <AsrCredentialField>[]) {
      final value = _credentialCtrl(field.key).text.trim();
      if (value.isEmpty && !field.optional) {
        MoeToast.show(context, '请输入 ${field.label}');
        return;
      }
      if (value.isNotEmpty) credentials[field.key] = value;
    }

    if (_isComfyUI) {
      try {
        ComfyUIImageAdapter.endpoint(apiBaseUrl, 'prompt');
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
      final customConfig =
          copyCustomConfigWithProviderChatApiPath(<String, dynamic>{
            if (asr == null) 'requestFormat': format.value,
            if (asr != null) AsrRequestFormat.configKey: asr.value,
            ...credentials,
            if (_isCustomRestTts)
              TtsRequestFormat.customRestTemplateKey: _ttsTemplate,
          }, apiPath);

      // 识别厂商都没有列模型的接口，直接用注册表里的默认模型。
      if (asr == null) {
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
                            MoeSegmentedControl<ProviderCategory>(
                              value: _category,
                              segments: ProviderCategory.values
                                  .map(
                                    (c) =>
                                        MoeSegment(value: c, label: c.label),
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
                              label:
                                  _selectedFormat.asr?.apiKeyLabel ?? 'API Key',
                              controller: _keyCtrl,
                              hintText: _selectedFormat.apiKeyOptional
                                  ? '可选（Bearer Token）'
                                  : '必填',
                            ),
                            for (final field
                                in _selectedFormat.asr?.credentialFields ??
                                    const <AsrCredentialField>[])
                              _buildInputRow(
                                colors,
                                icon: Icons.vpn_key_outlined,
                                label: field.label,
                                controller: _credentialCtrl(field.key),
                                hintText: field.optional ? '可选' : '必填',
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
                        if (_isComfyUI)
                          _buildHint(
                            '同机可用 127.0.0.1；手机连接电脑时填写电脑的局域网地址。添加后将自动拉取基础模型列表，可在绘图预设中绑定 LoRA 或导入自定义工作流 JSON。',
                            colors,
                          ),
                        if (_isCustomRestTts) ...[
                          const SizedBox(height: 16),
                          MoeSettingsGroup(
                            margin: EdgeInsets.zero,
                            children: [
                              MoeSettingsRow(
                                label: '请求模板',
                                detailText: '路径、请求头、请求体',
                                trailingType: MoeSettingsRowTrailing.text,
                                showDivider: false,
                                onTap: () async {
                                  final template =
                                      await showTtsRequestTemplateEditor(
                                        context,
                                        {
                                          TtsRequestFormat
                                                  .customRestTemplateKey:
                                              _ttsTemplate,
                                        },
                                      );
                                  if (template != null && mounted) {
                                    setState(() => _ttsTemplate = template);
                                  }
                                },
                              ),
                            ],
                          ),
                          _buildHint(
                            '适合没有内置格式的语音服务：按厂商文档改模板即可。模型列表可在添加后的详情页手动添加。',
                            colors,
                          ),
                        ],
                        for (final field
                            in _selectedFormat.asr?.credentialFields ??
                                const <AsrCredentialField>[])
                          if (field.hint != null)
                            _buildHint('${field.label}：${field.hint}', colors),
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
        .map((f) => MoeSegment(value: f, label: f.label))
        .toList();
    return LayoutBuilder(
      builder: (context, constraints) {
        final fits = constraints.maxWidth / formats.length >= _minItemWidth;
        final bar = MoeSegmentedControl<ApiFormat>(
          value: value,
          segments: items,
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

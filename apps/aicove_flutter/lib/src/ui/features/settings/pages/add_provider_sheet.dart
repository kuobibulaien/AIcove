/// AddProviderSheet - 娣诲姞渚涘簲鍟嗗簳閮ㄥ脊绐?
///
/// 璁捐鐗圭偣锛?
/// - 搴曢儴寮圭獥褰㈠紡
/// - 绗竴姝ワ細閫夋嫨 API 鏍煎紡锛圤penAI/Claude/Gemini锛?
/// - 绗簩姝ワ細濉啓鍩虹閰嶇疆锛堟樉绀哄悕绉般€丄PI Key銆丄PI 鍦板潃锛?
/// - 绗笁姝ワ細閫夋嫨妯″瀷鐢ㄩ€旓紙瀵硅瘽/宓屽叆/鍥剧墖/璇煶锛屽崟閫夛級
///
/// 鏇存柊璁板綍锛?
/// - 2026-02-21: NovelAI 绉诲叆鍐呯疆渚涘簲鍟嗗垪琛紝姝ゅ浠呬繚鐣?3 绉嶆爣鍑?API 鏍煎紡
/// - 2026-01-31: 绉婚櫎TTS鐢ㄩ€旂殑浜岀骇API鏍煎紡閫夋嫨
/// - 2026-01-25: 鐢ㄩ€旀敼涓哄閫夛紝涓€琛屼竴涓竷灞€
/// - 2026-01-22: 鐢ㄩ€旀敼涓哄崟閫夛紝API鏍煎紡鏀逛负涓夐€変竴鍒囨崲妗?
/// - 2026-01-21: 鍒涘缓娣诲姞渚涘簲鍟嗗簳閮ㄥ脊绐?
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:figma_squircle/figma_squircle.dart';

import '../../../../core/api/providers/google_api_mode.dart';
import '../../../../core/api/providers/provider_chat_api_path.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../theme/tokens.dart';
import '../../../shared/effects/smooth_clip.dart';
import '../../../shared/widgets/index.dart';

/// 鏄剧ず娣诲姞渚涘簲鍟嗗簳閮ㄥ脊绐?
Future<bool?> showAddProviderSheet(BuildContext context) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => const AddProviderSheet(),
  );
}

/// API 鏍煎紡
class ApiFormat {
  const ApiFormat._(
    this.value,
    this.label,
    this.defaultBaseUrl,
    this.defaultApiPath,
  );

  static const openai = ApiFormat._(
      'openai', 'OpenAI', 'https://api.openai.com/v1', '/chat/completions');
  static const claude = ApiFormat._(
      'claude', 'Claude', 'https://api.anthropic.com/v1', '/messages');
  static const gemini = ApiFormat._(
    'gemini',
    'Gemini',
    kGeminiDeveloperApiBase,
    '/models/{model}:generateContent',
  );
  static const novelai =
      ApiFormat._('novelai', 'NovelAI', 'https://image.novelai.net', '');

  static const chatFormats = <ApiFormat>[openai, claude, gemini];
  static const imageFormats = <ApiFormat>[openai, novelai];

  static List<ApiFormat> forCapability(String capability) {
    if (capability == 'image') return imageFormats;
    return chatFormats;
  }

  final String value;
  final String label;
  final String defaultBaseUrl;
  final String defaultApiPath;
}

/// 娣诲姞渚涘簲鍟嗗簳閮ㄥ脊绐?
class AddProviderSheet extends ConsumerStatefulWidget {
  const AddProviderSheet({super.key});

  @override
  ConsumerState<AddProviderSheet> createState() => _AddProviderSheetState();
}

class _AddProviderSheetState extends ConsumerState<AddProviderSheet> {
  final _displayCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _urlCtrl = TextEditingController(text: ApiFormat.openai.defaultBaseUrl);
  final _pathCtrl =
      TextEditingController(text: ApiFormat.openai.defaultApiPath);

  ApiFormat _selectedFormat = ApiFormat.openai;
  bool _vertexExpressEnabled = false;
  bool _submitting = false;

  @override
  void dispose() {
    _displayCtrl.dispose();
    _keyCtrl.dispose();
    _urlCtrl.dispose();
    _pathCtrl.dispose();
    super.dispose();
  }

  void _onFormatChanged(ApiFormat format) {
    setState(() {
      _selectedFormat = format;
      if (format == ApiFormat.gemini) {
        _urlCtrl.text =
            googleSuggestedBaseUrl(vertexExpress: _vertexExpressEnabled);
      } else {
        _urlCtrl.text = format.defaultBaseUrl;
      }
      _pathCtrl.text = format.defaultApiPath;
    });
  }

  void _onVertexExpressChanged(bool enabled) {
    setState(() {
      _vertexExpressEnabled = enabled;
      if (_selectedFormat == ApiFormat.gemini) {
        _urlCtrl.text = googleSuggestedBaseUrl(vertexExpress: enabled);
      }
    });
  }

  List<String> _pickDefaultVisibleModels(List<String> models) {
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

  Future<void> _submit() async {
    final apiKey = _keyCtrl.text.trim();
    final apiBaseUrl = _urlCtrl.text.trim();
    final apiPath = _pathCtrl.text.trim();
    final displayName = _displayCtrl.text.trim();

    if (apiKey.isEmpty) {
      MoeToast.show(context, '\u8bf7\u8f93\u5165 API Key');
      return;
    }
    if (apiBaseUrl.isEmpty) {
      MoeToast.show(context, '\u8bf7\u8f93\u5165 API \u5730\u5740');
      return;
    }
    if (apiPath.isEmpty) {
      MoeToast.show(context, '请输入 API 路径');
      return;
    }

    setState(() => _submitting = true);

    try {
      final notifier = ref.read(appSettingsProvider.notifier);
      var warningMessage = '';
      List<String> allModels = const <String>[];
      List<String> visibleModels = const <String>[];

      try {
        final preview = await notifier.previewProviderModels(
          providerId: _selectedFormat.value,
          apiKey: apiKey,
          apiBaseUrl: apiBaseUrl,
          customConfig: _selectedFormat == ApiFormat.gemini
              ? copyCustomConfigWithProviderChatApiPath(
                  <String, dynamic>{
                    kGoogleVertexExpressField: _vertexExpressEnabled,
                  },
                  apiPath,
                )
              : copyCustomConfigWithProviderChatApiPath(
                  const <String, dynamic>{},
                  apiPath,
                ),
        );
        allModels = preview;
        visibleModels = _pickDefaultVisibleModels(preview);
      } catch (_) {
        warningMessage =
            '\u65e0\u6cd5\u8fde\u63a5\u5230\u6a21\u578b\u670d\u52a1\uff0c\u5df2\u5148\u4fdd\u5b58\u6e20\u9053\u3002\u8bf7\u68c0\u67e5 API \u5730\u5740\u6216 Key\uff0c\u53ef\u5728\u8be6\u60c5\u9875\u5237\u65b0\u6a21\u578b\u5217\u8868\u3002';
      }

      await notifier.importCustomModel(
        name: null,
        apiKey: apiKey,
        apiBaseUrl: apiBaseUrl,
        provider: _selectedFormat.value,
        displayName: displayName.isNotEmpty ? displayName : null,
        allModels: allModels,
        visibleModels: visibleModels,
        customConfig: {
          'requestFormat': _selectedFormat.value,
          if (_selectedFormat == ApiFormat.gemini)
            kGoogleVertexExpressField: _vertexExpressEnabled,
          kProviderChatApiPathField:
              normalizeProviderChatApiPath(apiPath) ?? apiPath,
        },
      );

      if (!mounted) return;
      Navigator.of(context).pop(true);
      if (warningMessage.isEmpty) {
        MoeToast.show(context, '\u6dfb\u52a0\u6210\u529f');
      } else {
        MoeToast.show(context, warningMessage, type: ToastType.warning);
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
      return '\u6dfb\u52a0\u5931\u8d25\uff1aAPI Key \u4e0d\u80fd\u4e3a\u7a7a';
    }
    return '\u6dfb\u52a0\u5931\u8d25\uff1a$raw';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final viewInsets = MediaQuery.of(context).viewInsets;
    final screenHeight = MediaQuery.of(context).size.height;

    const sheetBorderRadius = SmoothBorderRadius.vertical(
      top: SmoothRadius(cornerRadius: 24, cornerSmoothing: 0.6),
    );

    // 涓嶆妸鏁翠釜 sheet 寰€涓婇《锛氬彧鍦ㄥ唴閮ㄥ唴瀹瑰尯缁欓敭鐩樿浣嶏紝瑙傛劅鏇村儚"杈撳叆鍖烘姮璧?銆?
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
                // 瑁呴グ鏉?
                Container(
                  margin: const EdgeInsets.only(top: 12, bottom: 8),
                  width: 32,
                  height: 4,
                  decoration: MoeG2Decoration(
                    radius: 2,
                    color: colors.border.withValues(alpha: 0.5),
                  ),
                ),

                // 鏍囬
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Row(
                    children: [
                      Text(
                        '\u6dfb\u52a0\u4f9b\u5e94\u5546',
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
                        // 1. 閫夋嫨 API 鏍煎紡
                        _buildSectionTitle('API \u683c\u5f0f', colors),
                        const SizedBox(height: 8),
                        MoeSettingsGroup(
                          margin: EdgeInsets.zero,
                          padding: const EdgeInsets.all(12),
                          borderRadius: BorderRadius.circular(20),
                          children: [
                            MoeToggleBar<ApiFormat>(
                              value: _selectedFormat,
                              items: ApiFormat.chatFormats
                                  .map((f) =>
                                      MoeToggleItem(value: f, label: f.label))
                                  .toList(),
                              onChanged: _onFormatChanged,
                            ),
                          ],
                        ),

                        const SizedBox(height: 20),

                        // 2. 鍩虹閰嶇疆
                        _buildSectionTitle('\u57fa\u7840\u914d\u7f6e', colors),
                        const SizedBox(height: 8),
                        MoeSettingsGroup(
                          margin: EdgeInsets.zero,
                          children: [
                            MoeSettingsRow(
                              icon: Icons.badge_outlined,
                              label: '\u663e\u793a\u540d\u79f0',
                              trailingType: MoeSettingsRowTrailing.custom,
                              trailing: SizedBox(
                                width: 160,
                                child: TextField(
                                  controller: _displayCtrl,
                                  textAlign: TextAlign.end,
                                  style: TextStyle(
                                      fontSize: 14, color: colors.text),
                                  decoration: InputDecoration(
                                    hintText: '\u53ef\u7559\u7a7a',
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
                                  obscureText: false,
                                  textAlign: TextAlign.end,
                                  style: TextStyle(
                                      fontSize: 14, color: colors.text),
                                  decoration: InputDecoration(
                                    hintText: '\u5fc5\u586b',
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
                              label: '基础 URL',
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
                            MoeSettingsRow(
                              icon: Icons.route_outlined,
                              label: 'API 路径',
                              trailingType: MoeSettingsRowTrailing.custom,
                              trailing: SizedBox(
                                width: 180,
                                child: TextField(
                                  controller: _pathCtrl,
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
                            if (_selectedFormat == ApiFormat.gemini)
                              MoeSettingsRow(
                                icon: Icons.cloud_sync_outlined,
                                label: 'Vertex Express',
                                subtitle: '开启后默认切到 aiplatform 端点',
                                trailingType: MoeSettingsRowTrailing.custom,
                                trailing: MoeSwitch(
                                  value: _vertexExpressEnabled,
                                  onChanged: _onVertexExpressChanged,
                                ),
                              ),
                          ],
                        ),
                        ValueListenableBuilder<TextEditingValue>(
                          valueListenable: _urlCtrl,
                          builder: (context, value, _) {
                            if (_selectedFormat != ApiFormat.openai ||
                                !shouldSuggestOpenAiBaseUrlV1(value.text)) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 10),
                                decoration: MoeG2Decoration(
                                  radius: MoeRadii.md,
                                  color:
                                      colors.surfaceAlt.withValues(alpha: 0.72),
                                  border: Border.all(
                                    color:
                                        colors.border.withValues(alpha: 0.45),
                                    width: 1,
                                  ),
                                ),
                                child: Text(
                                  'OpenAI 格式推荐让基础 URL 以 /v1 结尾，模型预览会更稳。',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colors.textSecondary,
                                    height: 1.35,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),

                        const SizedBox(height: 20),

                        const SizedBox(height: 24),

                        // 鎻愪氦鎸夐挳
                        Row(
                          children: [
                            Expanded(
                              child: MoeSecondaryButton(
                                label: '\u53d6\u6d88',
                                onPressed: () => Navigator.of(context).pop(),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: MoePrimaryButton(
                                label: _submitting
                                    ? '\u6dfb\u52a0\u4e2d...'
                                    : '\u7acb\u5373\u6dfb\u52a0',
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
}

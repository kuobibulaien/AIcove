/// ImportModelDialog - 导入新渠道对话框
/// 
/// 用于添加新的 AI 模型服务提供商。
/// 
/// 重构记录：
/// - 2025-12-31: 拆分为多个组件文件，主文件精简至约280行
///   - 提取 ModelTypeSelector 模型类型选择器
///   - 提取 ChannelTypeSelector 渠道类型选择器
///   - 提取 CustomBodyExpansion 高级设置
///   - 提取 ModelListSection 模型列表选择
///   - API格式选择改用底部弹窗 (MoeActionSheet)
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../features/settings/app_settings.dart';
import '../widgets/import_model_form_fields.dart';
import '../widgets/import_model_list_section.dart';

class ImportModelDialog extends ConsumerStatefulWidget {
  const ImportModelDialog({super.key});

  @override
  ConsumerState<ImportModelDialog> createState() => _ImportModelDialogState();
}

class _ImportModelDialogState extends ConsumerState<ImportModelDialog> {
  final _formKey = GlobalKey<FormState>();
  final _defaultModelCtrl = TextEditingController();
  final _displayCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _urlCtrl = TextEditingController(text: 'https://api.openai.com/v1');
  final _customBodyCtrl = TextEditingController();

  String _importFormat = 'openai';
  String _selectedPreset = 'openai';
  bool _submitting = false;
  bool _loadingModels = false;
  List<String> _loadedModels = const [];
  Set<String> _selectedModels = <String>{};
  String? _loadError;
  String _selectedModelType = 'chat';

  String get _providerId => _importFormat == 'doubao' ? 'doubao' : 'openai';

  @override
  void dispose() {
    _defaultModelCtrl.dispose();
    _displayCtrl.dispose();
    _keyCtrl.dispose();
    _urlCtrl.dispose();
    _customBodyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canPreview = _importFormat == 'openai';
    final screenWidth = MediaQuery.of(context).size.width;
    final dialogWidth = math.min(480.0, screenWidth - 32).clamp(0.0, 480.0);
    final colors = context.moeColors;

    return AlertDialog(
      title: const Text('导入新渠道'),
      content: SizedBox(
        width: dialogWidth,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 模型类型选择
                ModelTypeSelector(
                  selectedType: _selectedModelType,
                  onChanged: (value) => setState(() => _selectedModelType = value),
                ),

                const SizedBox(height: 12),

                // 渠道类型选择
                ChannelTypeSelector(
                  selectedPreset: _selectedPreset,
                  onChanged: _onPresetChanged,
                ),

                const SizedBox(height: 12),

                // 自定义渠道的 API 格式选择
                if (_selectedPreset == 'custom') ...[
                  Text(
                    'API 格式',
                    style: TextStyle(fontSize: 12, color: colors.textSecondary),
                  ),
                  const SizedBox(height: 4),
                  InkWell(
                    onTap: _showFormatSelector,
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                      decoration: BoxDecoration(
                        border: Border.all(color: colors.borderLight, width: borderWidth),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _importFormat == 'openai'
                                  ? 'OpenAI 兼容接口'
                                  : '豆包 Ark v3（暂不支持自动加载）',
                              style: TextStyle(fontSize: 15, color: colors.text),
                            ),
                          ),
                          Icon(Icons.arrow_drop_down, color: colors.muted),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

                // 基础表单字段
                TextFormField(
                  controller: _displayCtrl,
                  decoration: const InputDecoration(
                    labelText: '渠道显示名称（可选）',
                    hintText: '用于界面展示，可留空',
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _keyCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'API Key',
                    hintText: '必填：该渠道的授权密钥',
                  ),
                  validator: (value) => (value == null || value.trim().isEmpty) ? '请输入 API Key' : null,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _urlCtrl,
                  decoration: const InputDecoration(
                    labelText: 'API Base URL',
                    hintText: '例如 https://api.openai.com/v1',
                  ),
                  validator: (value) => (value == null || value.trim().isEmpty) ? '请输入 API Base URL' : null,
                ),

                const SizedBox(height: 12),

                // 高级设置
                CustomBodyExpansion(controller: _customBodyCtrl),

                const SizedBox(height: 12),

                // 模型列表选择
                ModelListSection(
                  loadedModels: _loadedModels,
                  selectedModels: _selectedModels,
                  loading: _loadingModels,
                  error: _loadError,
                  canPreview: canPreview,
                  defaultModelController: _defaultModelCtrl,
                  onLoadModels: _loadModels,
                  onModelToggle: (model, selected) {
                    setState(() {
                      if (selected) {
                        _selectedModels.add(model);
                      } else {
                        _selectedModels.remove(model);
                      }
                    });
                  },
                  onSelectAll: () => setState(() => _selectedModels = _loadedModels.toSet()),
                  onDeselectAll: () => setState(() => _selectedModels.clear()),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        MoeSecondaryButton(
          label: '取消',
          enabled: !_submitting,
          onPressed: () => Navigator.pop(context),
        ),
        MoePrimaryButton(
          label: '导入并显示',
          enabled: !_submitting,
          onPressed: _onSubmit,
        ),
      ],
    );
  }

  void _onPresetChanged(String value) {
    setState(() {
      _selectedPreset = value;
      if (value != 'custom' && ChannelPreset.presets.containsKey(value)) {
        _urlCtrl.text = ChannelPreset.presets[value]!.url;
      }
      if (value != 'doubao') {
        _importFormat = 'openai';
      }
    });
  }

  Future<void> _loadModels() async {
    final key = _keyCtrl.text.trim();
    if (key.isEmpty) {
      MoeToast.warning(context, '请先输入 API Key');
      return;
    }
    final baseUrl = _urlCtrl.text.trim();

    setState(() {
      _loadingModels = true;
      _loadError = null;
    });
    try {
      final models = await ref.read(appSettingsProvider.notifier).previewProviderModels(
            providerId: _providerId,
            apiKey: key,
            apiBaseUrl: baseUrl,
          );
      models.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      setState(() {
        _loadingModels = false;
        _loadedModels = models;
        _selectedModels = models.toSet();
        _loadError = null;
      });
      if (models.isEmpty) {
        if (!mounted) return;
        MoeToast.warning(context, '未获取到模型列表，请手动填写默认模型名称');
      }
    } catch (e) {
      setState(() {
        _loadingModels = false;
        _loadError = e.toString();
        _loadedModels = const [];
        _selectedModels = <String>{};
      });
    }
  }

  Future<void> _onSubmit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    if (_loadedModels.isNotEmpty && _selectedModels.isEmpty) {
      MoeToast.warning(context, '请至少选择一个要显示的模型');
      return;
    }

    setState(() => _submitting = true);
    try {
      final baseUrl = _urlCtrl.text.trim();
      final displayName = _displayCtrl.text.trim().isEmpty ? null : _displayCtrl.text.trim();
      final defaultModel = _defaultModelCtrl.text.trim().isEmpty ? null : _defaultModelCtrl.text.trim();
      final visible = _loadedModels.isEmpty ? <String>[] : _selectedModels.toList();
      final hidden = _loadedModels.isEmpty ? <String>[] : _loadedModels.where((m) => !_selectedModels.contains(m)).toList();

      Map<String, dynamic>? customConfig;
      if (_customBodyCtrl.text.trim().isNotEmpty) {
        try {
          customConfig = jsonDecode(_customBodyCtrl.text.trim());
        } catch (_) {}
      }

      await ref.read(appSettingsProvider.notifier).importCustomModel(
            name: defaultModel,
            displayName: displayName,
            apiKey: _keyCtrl.text.trim(),
            apiBaseUrl: baseUrl,
            provider: _providerId,
            visibleModels: visible.isEmpty ? null : visible,
            hiddenModels: hidden.isEmpty ? null : hidden,
            allModels: _loadedModels.isEmpty ? null : _loadedModels,
            capabilities: [_selectedModelType],
            customConfig: customConfig,
            modelType: _selectedModelType,
          );
      if (!mounted) return;
      Navigator.pop(context);
      MoeToast.success(context, '导入成功，已同步到后端');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _showFormatSelector() {
    showMoeActionSheet(
      context: context,
      title: '选择导入格式',
      actions: [
        MoeSheetAction(
          icon: Icons.api,
          label: 'OpenAI 兼容接口',
          subtitle: '支持自动加载模型列表',
          onTap: () => _applyFormat('openai'),
        ),
        MoeSheetAction(
          icon: Icons.cloud,
          label: '豆包 Ark v3',
          subtitle: '暂不支持自动加载',
          onTap: () => _applyFormat('doubao'),
        ),
      ],
    );
  }

  void _applyFormat(String format) {
    if (format == _importFormat) return;
    setState(() {
      _importFormat = format;
      if (_importFormat == 'doubao') {
        if (_urlCtrl.text.trim().isEmpty || _urlCtrl.text.trim() == 'https://api.openai.com/v1') {
          _urlCtrl.text = 'https://ark.cn-beijing.volces.com/api/v3';
        }
        if (_defaultModelCtrl.text.trim().isEmpty) {
          _defaultModelCtrl.text = 'doubao-seed-1-6-251015';
        }
      } else {
        if (_urlCtrl.text.trim().isEmpty || _urlCtrl.text.trim() == 'https://ark.cn-beijing.volces.com/api/v3') {
          _urlCtrl.text = 'https://api.openai.com/v1';
        }
      }
      _loadedModels = const [];
      _selectedModels = <String>{};
      _loadError = null;
    });
  }
}

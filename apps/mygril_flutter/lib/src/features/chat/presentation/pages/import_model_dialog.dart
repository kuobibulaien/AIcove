import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/tokens.dart';
import '../../../settings/app_settings.dart';

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
  String _selectedPreset = 'openai'; // openai, newapi, siliconflow, deepseek, custom
  bool _submitting = false;
  bool _loadingModels = false;
  List<String> _loadedModels = const [];
  Set<String> _selectedModels = <String>{};
  String? _loadError;
  String _selectedModelType = 'chat'; // 选中的模型类型：chat, embedding, tts, stt, image

  String get _providerId => _importFormat == 'doubao' ? 'doubao' : 'openai';

  final Map<String, Map<String, String>> _presets = {
    'openai': {
      'label': 'OpenAI (默认)',
      'url': 'https://api.openai.com/v1',
    },
    'newapi': {
      'label': 'NewAPI / OneAPI',
      'url': 'https://api.openai.com/v1',
    },
    'siliconflow': {
      'label': '硅基流动 (SiliconFlow)',
      'url': 'https://api.siliconflow.cn/v1',
    },
    'deepseek': {
      'label': 'DeepSeek',
      'url': 'https://api.deepseek.com',
    },
    'custom': {
      'label': '自定义渠道',
      'url': '',
    },
  };

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
                const Text(
                  '模型类型',
                  style: TextStyle(fontSize: 12, color: moeTextSecondary),
                ),
                const SizedBox(height: 4),
                DropdownButtonFormField<String>(
                  value: _selectedModelType,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'chat',
                      child: Row(
                        children: [
                          Icon(Icons.chat_bubble_outline, size: 18),
                          SizedBox(width: 8),
                          Text('基础对话'),
                        ],
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'embedding',
                      child: Row(
                        children: [
                          Icon(Icons.code_outlined, size: 18),
                          SizedBox(width: 8),
                          Text('嵌入(Embedding)'),
                        ],
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'tts',
                      child: Row(
                        children: [
                          Icon(Icons.volume_up_outlined, size: 18),
                          SizedBox(width: 8),
                          Text('文字转语音'),
                        ],
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'stt',
                      child: Row(
                        children: [
                          Icon(Icons.mic_outlined, size: 18),
                          SizedBox(width: 8),
                          Text('语音转文字'),
                        ],
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'image',
                      child: Row(
                        children: [
                          Icon(Icons.image_outlined, size: 18),
                          SizedBox(width: 8),
                          Text('图像生成'),
                        ],
                      ),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setState(() {
                        _selectedModelType = value;
                      });
                    }
                  },
                ),

                const SizedBox(height: 12),
                const Text(
                  '渠道类型',
                  style: TextStyle(fontSize: 12, color: moeTextSecondary),
                ),
                const SizedBox(height: 4),
                DropdownButtonFormField<String>(
                  value: _selectedPreset,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  ),
                  items: _presets.entries.map((e) {
                    return DropdownMenuItem(
                      value: e.key,
                      child: Text(e.value['label']!),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setState(() {
                        _selectedPreset = value;
                        if (value != 'custom') {
                          _urlCtrl.text = _presets[value]!['url']!;
                        }
                        // Reset format if switching back to standard presets
                        if (value != 'doubao') {
                           _importFormat = 'openai';
                        }
                      });
                    }
                  },
                ),
                
                const SizedBox(height: 12),
                if (_selectedPreset == 'custom') ...[
                   const Text(
                    'API 格式',
                    style: TextStyle(fontSize: 12, color: moeTextSecondary),
                  ),
                  const SizedBox(height: 4),
                  InkWell(
                    onTap: _showFormatSelector,
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                      decoration: BoxDecoration(
                        border: Border.all(color: moeBorderLight, width: borderWidth),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _importFormat == 'openai'
                                  ? 'OpenAI 兼容接口'
                                  : '豆包 Ark v3（暂不支持自动加载）',
                              style: const TextStyle(fontSize: 15, color: moeText),
                            ),
                          ),
                          const Icon(Icons.arrow_drop_down, color: moeMuted),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

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
                ExpansionTile(
                  title: const Text('高级设置：自定义请求体', style: TextStyle(fontSize: 14)),
                  tilePadding: EdgeInsets.zero,
                  children: [
                    TextFormField(
                      controller: _customBodyCtrl,
                      maxLines: 3,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      decoration: const InputDecoration(
                        hintText: '{"model": "gpt-4", "temperature": 0.7}',
                        helperText: 'JSON 格式，将合并到请求体中',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        if (value != null && value.trim().isNotEmpty) {
                          try {
                            jsonDecode(value);
                          } catch (e) {
                            return 'JSON 格式错误';
                          }
                        }
                        return null;
                      },
                    ),
                  ],
                ),

                const SizedBox(height: 12),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: canPreview && !_loadingModels ? _loadModels : null,
                      icon: _loadingModels
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.cloud_download_outlined),
                      label: Text(_loadingModels ? '加载中…' : '加载模型列表'),
                    ),
                    const SizedBox(width: 12),
                    if (!canPreview)
                      const Expanded(
                        child: Text(
                          '当前模式暂不支持自动加载，请手动填写默认模型。',
                          style: TextStyle(color: moeMuted, fontSize: 12),
                        ),
                      )
                    else if (_loadedModels.isNotEmpty)
                      Text('共 ${_loadedModels.length} 个模型', style: const TextStyle(color: moeMuted, fontSize: 12)),
                  ],
                ),
                
                if (_loadError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _loadError!,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                  ),
                ],

                if (!canPreview || _loadedModels.isEmpty) ...[
                   const SizedBox(height: 8),
                   TextFormField(
                    controller: _defaultModelCtrl,
                    decoration: const InputDecoration(
                      labelText: '默认模型名称',
                      hintText: '例如：gpt-4o',
                    ),
                    validator: (value) {
                      if ((!canPreview || _loadedModels.isEmpty) && (value == null || value.trim().isEmpty)) {
                        return '请填写默认模型名称';
                      }
                      return null;
                    },
                  ),
                ],

                if (_loadedModels.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('选择要显示的模型', style: TextStyle(fontWeight: FontWeight.w600)),
                      Row(
                        children: [
                          TextButton(
                            onPressed: () => setState(() => _selectedModels = _loadedModels.toSet()),
                            child: const Text('全选'),
                          ),
                          TextButton(
                            onPressed: () => setState(() => _selectedModels.clear()),
                            child: const Text('全不选'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  SizedBox(
                    height: 200,
                    child: Scrollbar(
                      child: ListView.builder(
                        itemCount: _loadedModels.length,
                        itemBuilder: (context, index) {
                          final model = _loadedModels[index];
                          final checked = _selectedModels.contains(model);
                          return CheckboxListTile(
                            dense: true,
                            value: checked,
                            title: Text(model),
                            onChanged: (value) {
                              setState(() {
                                if (value == true) {
                                  _selectedModels.add(model);
                                } else {
                                  _selectedModels.remove(model);
                                }
                              });
                            },
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _onSubmit,
          child: _submitting
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('导入并显示'),
        ),
      ],
    );
  }

  Future<void> _loadModels() async {
    final key = _keyCtrl.text.trim();
    if (key.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先输入 API Key'), duration: Duration(seconds: 1)));
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未获取到模型列表，请手动填写默认模型名称'), duration: Duration(seconds: 1)),
        );
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请至少选择一个要显示的模型'), duration: Duration(seconds: 1)));
      return;
    }

    setState(() => _submitting = true);
    try {
      final baseUrl = _urlCtrl.text.trim();
      final displayName = _displayCtrl.text.trim().isEmpty ? null : _displayCtrl.text.trim();
      final defaultModel = _defaultModelCtrl.text.trim().isEmpty ? null : _defaultModelCtrl.text.trim();
      final visible = _loadedModels.isEmpty ? <String>[] : _selectedModels.toList();
      final hidden =
          _loadedModels.isEmpty ? <String>[] : _loadedModels.where((m) => !_selectedModels.contains(m)).toList();
      
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
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('导入成功，已同步到后端'), duration: Duration(seconds: 1)));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _showFormatSelector() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: moeSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '选择导入格式',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: moeText,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: moeMuted),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              const Divider(height: 0, thickness: borderWidth, color: moeDividerColor),
              ListTile(
                leading: const Icon(Icons.api, color: moePrimary),
                title: const Text('OpenAI 兼容接口'),
                subtitle: const Text('支持自动加载模型列表', style: TextStyle(fontSize: 12, color: moeMuted)),
                selected: _importFormat == 'openai',
                selectedTileColor: moeSurfaceAlt,
                onTap: () => Navigator.pop(context, 'openai'),
              ),
              const Divider(height: 0, thickness: borderWidth, color: moeDividerColor),
              ListTile(
                leading: const Icon(Icons.cloud, color: moePrimary),
                title: const Text('豆包 Ark v3'),
                subtitle: const Text('暂不支持自动加载', style: TextStyle(fontSize: 12, color: moeMuted)),
                selected: _importFormat == 'doubao',
                selectedTileColor: moeSurfaceAlt,
                onTap: () => Navigator.pop(context, 'doubao'),
              ),
            ],
          ),
        );
      },
    );

    if (selected != null && selected != _importFormat) {
      setState(() {
        _importFormat = selected;
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
}



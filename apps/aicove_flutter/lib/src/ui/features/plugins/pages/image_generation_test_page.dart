import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/plugins/image/image_config.dart';
import '../../../../features/plugins/image/drawing_preset_provider.dart';
import '../../../../features/plugins/image/image_plugin.dart';
import '../../../../features/plugins/plugin_providers.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

class ImageGenerationTestPage extends ConsumerStatefulWidget {
  final String? initialProviderLabel;
  final String? initialModelLabel;
  final ImageConfig? drawingConfig;

  const ImageGenerationTestPage({
    super.key,
    this.initialProviderLabel,
    this.initialModelLabel,
    this.drawingConfig,
  });

  @override
  ConsumerState<ImageGenerationTestPage> createState() =>
      _ImageGenerationTestPageState();
}

enum _ImageTestStatus { idle, testing, success, error }

class _ImageGenerationTestPageState
    extends ConsumerState<ImageGenerationTestPage> {
  final _promptController = TextEditingController(
    text: '1girl, soft smile, detailed eyes, warm light, upper body portrait',
  );

  _ImageTestStatus _status = _ImageTestStatus.idle;
  String? _error;
  List<String> _localPaths = const [];
  String? _resolvedPrompt;
  String? _negativePrompt;
  String? _providerId;
  String? _modelId;
  int _selectedIndex = 0;

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _runTest() async {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) {
      MoeToast.warning(context, '请输入生图提示词');
      return;
    }

    final settings = ref.read(appSettingsProvider).valueOrNull;
    if (settings == null) {
      MoeToast.warning(context, '设置加载中，请稍后再试');
      return;
    }
    if (!settings.imageGenerationEnabled) {
      MoeToast.warning(context, '请先启用绘图工具');
      return;
    }

    final imagePlugin = widget.drawingConfig == null
        ? ref.read(pluginManagerProvider).getPlugin('image') as ImagePlugin?
        : null;
    final testPort = widget.drawingConfig == null
        ? null
        : ref.read(drawingPresetTestProvider(widget.drawingConfig!));
    if (imagePlugin == null && testPort == null) {
      MoeToast.warning(context, '未找到绘图插件');
      return;
    }

    setState(() {
      _status = _ImageTestStatus.testing;
      _error = null;
      _localPaths = const [];
      _resolvedPrompt = null;
      _negativePrompt = null;
      _providerId = null;
      _modelId = null;
      _selectedIndex = 0;
    });

    try {
      final rawResult = testPort != null
          ? await testPort.generate(prompt)
          : await imagePlugin!.runDrawImageToolForDebug(prompt: prompt);
      if (!mounted) return;
      final payload = _decodePayload(rawResult);
      final success = payload['success'] == true;
      final images = _extractLocalPaths(payload['images']);

      if (!success || images.isEmpty) {
        setState(() {
          _status = _ImageTestStatus.error;
          _error =
              _stringValue(payload['error']) ??
              (images.isEmpty ? '工具返回成功但没有图片' : '生图测试失败');
          _providerId = _stringValue(payload['provider']);
          _modelId = _stringValue(payload['model']);
          _resolvedPrompt = _stringValue(payload['prompt']);
          _negativePrompt = _stringValue(payload['negative_prompt']);
        });
        return;
      }

      setState(() {
        _status = _ImageTestStatus.success;
        _localPaths = images;
        _providerId = _stringValue(payload['provider']);
        _modelId = _stringValue(payload['model']);
        _resolvedPrompt = _stringValue(payload['prompt']);
        _negativePrompt = _stringValue(payload['negative_prompt']);
        _selectedIndex = 0;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = _ImageTestStatus.error;
        _error = '测试失败: $e';
      });
    }
  }

  void _clearResult() {
    if (_status == _ImageTestStatus.idle &&
        _error == null &&
        _localPaths.isEmpty &&
        _resolvedPrompt == null &&
        _negativePrompt == null &&
        _providerId == null &&
        _modelId == null) {
      return;
    }
    setState(() {
      _status = _ImageTestStatus.idle;
      _error = null;
      _localPaths = const [];
      _resolvedPrompt = null;
      _negativePrompt = null;
      _providerId = null;
      _modelId = null;
      _selectedIndex = 0;
    });
  }

  Map<String, dynamic> _decodePayload(String? rawResult) {
    final text = rawResult?.trim() ?? '';
    if (text.isEmpty) {
      return const {'success': false, 'error': '绘图工具未返回结果'};
    }
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry('$key', value));
    }
    return const {'success': false, 'error': '绘图工具返回了无法识别的结果'};
  }

  List<String> _extractLocalPaths(dynamic images) {
    if (images is! List) return const [];
    return images
        .map((item) {
          if (item is Map && item['localPath'] is String) {
            return item['localPath'] as String;
          }
          return null;
        })
        .whereType<String>()
        .toList(growable: false);
  }

  String? _stringValue(dynamic value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty || text == 'null') {
      return null;
    }
    return text;
  }

  void _openPreview() {
    if (_localPaths.isEmpty) return;
    MoeImagePreview.showGallery(
      context,
      images: [
        for (var i = 0; i < _localPaths.length; i += 1)
          ImagePreviewItem(
            provider: FileImage(File(_localPaths[i])),
            heroTag: 'image_test_preview_$i',
          ),
      ],
      initialIndex: _selectedIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final settingsAsync = ref.watch(appSettingsProvider);
    final ImageConfig config =
        widget.drawingConfig ??
        ref.watch<ImageConfig>(imagePluginConfigProvider);

    return MoePageScaffold(
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(title: '生图测试', showBackButton: true),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载设置失败: $e')),
        data: (settings) {
          final provider = settings.providers
              .where((p) => p.id == config.selectedProviderId)
              .firstOrNull;
          final providerLabel =
              widget.initialProviderLabel ??
              provider?.displayName ??
              provider?.id ??
              '未选择渠道';
          final modelLabel = config.selectedModelId == null
              ? widget.initialModelLabel ?? '未匹配到可用绘图模型'
              : settings.getModelDisplayName(config.selectedModelId!);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildSummaryCard(
                colors: colors,
                settings: settings,
                config: config,
                providerLabel: providerLabel,
                modelLabel: modelLabel,
              ),
              const SizedBox(height: 16),
              _buildComposerCard(colors),
              const SizedBox(height: 16),
              _buildResultCard(colors, config),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSummaryCard({
    required MoeColors colors,
    required AppSettings settings,
    required ImageConfig config,
    required String providerLabel,
    required String modelLabel,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: MoeG2Decoration(
        radius: 16,
        color: colors.panel,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '当前测试配置',
                style: TextStyle(
                  color: colors.text,
                  fontSize: 16,
                  fontWeight: MoeFontWeights.emphasis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            settings.imageGenerationEnabled ? '绘图工具已启用' : '绘图工具当前未启用',
            style: TextStyle(
              color: settings.imageGenerationEnabled
                  ? colors.primary
                  : colors.accent,
              fontSize: 13,
              fontWeight: MoeFontWeights.emphasis,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '渠道：$providerLabel',
            style: TextStyle(color: colors.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            '模型：$modelLabel',
            style: TextStyle(color: colors.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            '尺寸：${config.defaultWidth} x ${config.defaultHeight}  ·  步数：${config.defaultSteps}  ·  张数：${config.defaultCount}',
            style: TextStyle(color: colors.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            '说明：这里固定走 `draw_image` 工具链，仍会拼接当前画师串和默认负面词。',
            style: TextStyle(color: colors.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildComposerCard(MoeColors colors) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: MoeG2Decoration(
        radius: 16,
        color: colors.panel,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '测试提示词',
            style: TextStyle(
              color: colors.text,
              fontSize: 15,
              fontWeight: MoeFontWeights.emphasis,
            ),
          ),
          const SizedBox(height: 8),
          MoeTextField(
            controller: _promptController,
            maxLines: 5,
            hint: '输入要直接测试的生图提示词...',
            fillColor: colors.surface,
            borderColor: colors.border,
            focusBorderColor: colors.primary,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
            onChanged: (_) => _clearResult(),
          ),
          const SizedBox(height: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MoePrimaryButton(
                label: _status == _ImageTestStatus.testing ? '生成中...' : '开始测试',
                enabled: _status != _ImageTestStatus.testing,
                onPressed: _runTest,
              ),
              const SizedBox(height: 12),
              MoeSecondaryButton(
                label: '清空结果',
                enabled: _status != _ImageTestStatus.testing,
                onPressed: _clearResult,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildResultCard(MoeColors colors, ImageConfig config) {
    switch (_status) {
      case _ImageTestStatus.idle:
        return Container(
          padding: const EdgeInsets.all(20),
          decoration: MoeG2Decoration(
            radius: 16,
            color: colors.panel,
            border: Border.all(color: colors.border),
          ),
          child: Column(
            children: [
              Icon(Icons.image_search_outlined, color: colors.muted, size: 32),
              const SizedBox(height: 10),
              Text(
                '结果会显示在这里',
                style: TextStyle(
                  color: colors.text,
                  fontSize: 15,
                  fontWeight: MoeFontWeights.emphasis,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '成功后会直接展示返回图片，失败时会展示原始错误。',
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.textSecondary, fontSize: 13),
              ),
            ],
          ),
        );
      case _ImageTestStatus.testing:
        return Container(
          padding: const EdgeInsets.all(20),
          decoration: MoeG2Decoration(
            radius: 16,
            color: colors.panel,
            border: Border.all(color: colors.border),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  valueColor: AlwaysStoppedAnimation(colors.primary),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '正在请求当前绘图模型，请稍等...',
                  style: TextStyle(color: colors.textSecondary, fontSize: 13),
                ),
              ),
            ],
          ),
        );
      case _ImageTestStatus.error:
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: MoeG2Decoration(
            radius: 16,
            color: colors.panel,
            border: Border.all(color: colors.accent.withValues(alpha: 0.28)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.error_outline, color: colors.accent, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    '测试失败',
                    style: TextStyle(
                      color: colors.accent,
                      fontSize: 15,
                      fontWeight: MoeFontWeights.emphasis,
                    ),
                  ),
                ],
              ),
              if (_providerId != null || _modelId != null) ...[
                const SizedBox(height: 8),
                Text(
                  '渠道：${_providerId ?? '-'} / 模型：${_modelId ?? '-'}',
                  style: TextStyle(color: colors.textSecondary, fontSize: 13),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                SelectableText(
                  _error!,
                  style: TextStyle(color: colors.textSecondary, fontSize: 13),
                ),
              ],
            ],
          ),
        );
      case _ImageTestStatus.success:
        final safeIndex = _selectedIndex.clamp(0, _localPaths.length - 1);
        final currentPath = _localPaths[safeIndex];
        final aspectRatio = config.defaultWidth / config.defaultHeight;
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: MoeG2Decoration(
            radius: 16,
            color: colors.panel,
            border: Border.all(color: colors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.check_circle, color: colors.primary, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    '测试成功',
                    style: TextStyle(
                      color: colors.primary,
                      fontSize: 15,
                      fontWeight: MoeFontWeights.emphasis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              GestureDetector(
                onTap: _openPreview,
                child: SmoothClipRRect(
                  radius: 18,
                  child: Container(
                    color: colors.surface,
                    child: AspectRatio(
                      aspectRatio: aspectRatio,
                      child: Image.file(
                        File(currentPath),
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Center(
                          child: Text(
                            '图片预览失败',
                            style: TextStyle(color: colors.muted, fontSize: 13),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '点击大图可全屏查看',
                style: TextStyle(color: colors.muted, fontSize: 12),
              ),
              if (_localPaths.length > 1) ...[
                const SizedBox(height: 12),
                SizedBox(
                  height: 92,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _localPaths.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (context, index) {
                      final isSelected = index == safeIndex;
                      return GestureDetector(
                        onTap: () => setState(() => _selectedIndex = index),
                        child: Container(
                          width: 72,
                          padding: const EdgeInsets.all(2),
                          decoration: MoeG2Decoration(
                            radius: 12,
                            color: colors.surface,
                            border: Border.all(
                              color: isSelected
                                  ? colors.primary
                                  : colors.borderLight,
                              width: isSelected ? 1.6 : 1,
                            ),
                          ),
                          child: SmoothClipRRect(
                            radius: 10,
                            child: Image.file(
                              File(_localPaths[index]),
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                '渠道：${_providerId ?? '-'} / 模型：${_modelId ?? '-'}',
                style: TextStyle(color: colors.textSecondary, fontSize: 13),
              ),
              if (_resolvedPrompt != null) ...[
                const SizedBox(height: 12),
                Text(
                  '实际提示词',
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 13,
                    fontWeight: MoeFontWeights.emphasis,
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  _resolvedPrompt!,
                  style: TextStyle(color: colors.textSecondary, fontSize: 13),
                ),
              ],
              if (_negativePrompt != null) ...[
                const SizedBox(height: 12),
                Text(
                  '负面提示词',
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 13,
                    fontWeight: MoeFontWeights.emphasis,
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  _negativePrompt!,
                  style: TextStyle(color: colors.textSecondary, fontSize: 13),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                currentPath,
                style: TextStyle(color: colors.muted, fontSize: 11),
              ),
            ],
          ),
        );
    }
  }
}

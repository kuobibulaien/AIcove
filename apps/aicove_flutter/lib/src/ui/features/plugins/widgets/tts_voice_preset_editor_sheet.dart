library;

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../features/plugins/plugin_providers.dart';
import '../../../../features/plugins/tts/tts_available_models.dart';
import '../../../../features/plugins/tts/providers/tts_voice_provider.dart';
import '../../../../features/plugins/tts/tts_config.dart';
import '../../../../features/plugins/tts/tts_provider_context.dart';
import '../../../../features/plugins/tts/tts_voice_catalog_service.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

Future<void> showTtsVoicePresetEditorSheet({
  required BuildContext context,
  required TtsPluginConfigNotifier notifier,
  required TtsProviderContext providerContext,
  required AppSettings? settings,
  required List<TtsAvailableModelEntry> availableModels,
  required MoeColors colors,
  VoicePreset? preset,
}) {
  return showMoeBottomSheet(
    context: context,
    title: preset == null ? '自定义音色' : '编辑音色',
    builder: (sheetContext) => _TtsVoicePresetEditorSheetContent(
      parentContext: context,
      notifier: notifier,
      providerContext: providerContext,
      settings: settings,
      availableModels: availableModels,
      colors: colors,
      preset: preset,
    ),
  );
}

class _TtsVoicePresetEditorSheetContent extends StatefulWidget {
  final BuildContext parentContext;
  final TtsPluginConfigNotifier notifier;
  final TtsProviderContext providerContext;
  final AppSettings? settings;
  final List<TtsAvailableModelEntry> availableModels;
  final MoeColors colors;
  final VoicePreset? preset;

  const _TtsVoicePresetEditorSheetContent({
    required this.parentContext,
    required this.notifier,
    required this.providerContext,
    required this.settings,
    required this.availableModels,
    required this.colors,
    required this.preset,
  });

  @override
  State<_TtsVoicePresetEditorSheetContent> createState() =>
      _TtsVoicePresetEditorSheetContentState();
}

class _TtsVoicePresetEditorSheetContentState
    extends State<_TtsVoicePresetEditorSheetContent> {
  late final TextEditingController _nameController;
  late final TextEditingController _audioUrlController;
  late final TextEditingController _promptTextController;
  late final TextEditingController _manualVoiceIdController;
  late List<VoiceChannelBinding> _bindings;

  String? _selectedBindingProviderId;
  String? _selectedBindingModelId;
  String? _localAudioPath;
  String? _localAudioFileName;
  bool _submitting = false;

  bool get _isEdit => widget.preset != null;

  bool get _isBuiltIn => widget.preset?.isBuiltIn ?? false;

  bool get _hasUrlInput => _audioUrlController.text.trim().isNotEmpty;

  bool get _hasLocalFile =>
      _localAudioPath != null && _localAudioPath!.trim().isNotEmpty;

  bool get _hasReferenceAudio => _hasUrlInput || _hasLocalFile;

  TtsAvailableModelEntry? get _selectedBindingEntry {
    final providerId = _selectedBindingProviderId;
    final modelId = _selectedBindingModelId;
    if (providerId == null || modelId == null) return null;
    for (final entry in widget.availableModels) {
      if (entry.providerId == providerId && entry.modelId == modelId) {
        return entry;
      }
    }
    return null;
  }

  TtsProviderContext? get _selectedBindingContext {
    final entry = _selectedBindingEntry;
    if (entry == null) return null;
    return TtsProviderContext.resolveForSelection(
      config: widget.providerContext.config,
      settings: widget.settings,
      providerId: entry.providerId,
      modelId: entry.modelId,
    );
  }

  TtsCapabilities? get _selectedBindingCapabilities =>
      _selectedBindingContext?.capabilities;

  bool get _canCreateBinding {
    final bindingContext = _selectedBindingContext;
    if (bindingContext == null) return false;
    return bindingContext.hasVoiceProvider &&
        bindingContext.hasApiKey &&
        !_isBuiltIn &&
        !_submitting;
  }

  @override
  void initState() {
    super.initState();
    final preset = widget.preset;
    _nameController = TextEditingController(text: preset?.name ?? '');
    _audioUrlController =
        TextEditingController(text: preset?.promptAudioUrl ?? '');
    _promptTextController =
        TextEditingController(text: preset?.promptText ?? '');
    _manualVoiceIdController = TextEditingController();
    _bindings = [
      ...(preset?.effectiveBindings ?? const <VoiceChannelBinding>[])
    ];
    _localAudioPath = preset?.localAudioPath;
    _localAudioFileName = _extractFileName(_localAudioPath);
    final initialEntry = _resolveInitialBindingEntry();
    _selectedBindingProviderId = initialEntry?.providerId;
    _selectedBindingModelId = initialEntry?.modelId;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _audioUrlController.dispose();
    _promptTextController.dispose();
    _manualVoiceIdController.dispose();
    super.dispose();
  }

  Future<void> _pickLocalFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;

      final picked = result.files.first;
      if (picked.path == null) {
        final parentContext = widget.parentContext;
        if (!parentContext.mounted) return;
        MoeToast.warning(parentContext, '无法读取文件');
        return;
      }

      final sourceFile = File(picked.path!);
      final bytes = await sourceFile.readAsBytes();
      final appDir = await getApplicationDocumentsDirectory();
      final voicesDir = Directory('${appDir.path}/voices');
      if (!await voicesDir.exists()) {
        await voicesDir.create(recursive: true);
      }

      final fileName =
          '${DateTime.now().millisecondsSinceEpoch}_${picked.name}';
      final savedFile = File('${voicesDir.path}/$fileName');
      await savedFile.writeAsBytes(bytes);

      if (_localAudioPath != null &&
          _localAudioPath != widget.preset?.localAudioPath) {
        _deleteFileIfNeeded(_localAudioPath);
      }

      setState(() {
        _localAudioPath = savedFile.path;
        _localAudioFileName = picked.name;
      });
    } catch (e) {
      final parentContext = widget.parentContext;
      if (!parentContext.mounted) return;
      MoeToast.error(parentContext, '文件选择失败: $e');
    }
  }

  TtsAvailableModelEntry? _resolveInitialBindingEntry() {
    final selectedProviderId = widget.providerContext.providerAuth?.id;
    final selectedModelId = widget.providerContext.selectedModelId;
    if (selectedProviderId != null &&
        selectedProviderId.isNotEmpty &&
        selectedModelId != null &&
        selectedModelId.isNotEmpty) {
      for (final entry in widget.availableModels) {
        if (entry.providerId == selectedProviderId &&
            entry.modelId == selectedModelId) {
          return entry;
        }
      }
    }

    for (final binding in _bindings) {
      for (final entry in widget.availableModels) {
        if (entry.providerId == binding.providerId &&
            (binding.modelId == null || entry.modelId == binding.modelId)) {
          return entry;
        }
      }
    }

    if (widget.availableModels.isEmpty) return null;
    return widget.availableModels.first;
  }

  void _showBindingModelSelector() {
    if (widget.availableModels.isEmpty) {
      MoeToast.warning(widget.parentContext, '暂无已配置 key 的 TTS 模型');
      return;
    }

    showMoeActionSheet(
      context: context,
      title: '选择渠道模型',
      description: '只显示已配置 key 的 TTS 模型',
      actions: widget.availableModels.map((entry) {
        final isSelected = entry.providerId == _selectedBindingProviderId &&
            entry.modelId == _selectedBindingModelId;
        return MoeSheetAction(
          icon: isSelected ? Icons.check_circle : Icons.graphic_eq,
          label: entry.displayName,
          subtitle: entry.providerName,
          onTap: () {
            setState(() {
              _selectedBindingProviderId = entry.providerId;
              _selectedBindingModelId = entry.modelId;
            });
          },
        );
      }).toList(),
    );
  }

  Future<void> _createBindingForSelectedChannel() async {
    final entry = _selectedBindingEntry;
    final bindingContext = _selectedBindingContext;
    if (entry == null || bindingContext == null) {
      MoeToast.warning(widget.parentContext, '请先选择渠道模型');
      return;
    }
    if (!bindingContext.hasVoiceProvider) {
      MoeToast.warning(widget.parentContext, '当前渠道暂不支持在线创建，可改用手填音色 ID');
      return;
    }
    if (!bindingContext.hasApiKey) {
      MoeToast.warning(widget.parentContext, '当前渠道缺少 API Key');
      return;
    }
    final name = _nameController.text.trim();
    final promptText = _promptTextController.text.trim();
    if (name.isEmpty) {
      MoeToast.warning(widget.parentContext, '请先填写音色名称');
      return;
    }
    if (!_hasReferenceAudio) {
      MoeToast.warning(widget.parentContext, '请先提供参考音频，再生成渠道音色');
      return;
    }

    final capabilities = bindingContext.capabilities;
    final needsPromptText = capabilities?.needsPromptText ?? false;
    if (needsPromptText && promptText.isEmpty) {
      MoeToast.warning(widget.parentContext, '当前渠道要求填写参考文本');
      return;
    }

    Uint8List? audioBytes;
    String? fileName;
    String? requestAudioUrl;

    if (_hasLocalFile && (capabilities?.canUploadFile ?? false)) {
      final file = File(_localAudioPath!);
      audioBytes = await file.readAsBytes();
      fileName = _extractFileName(_localAudioPath);
    } else if (_hasUrlInput && (capabilities?.canUploadUrl ?? false)) {
      requestAudioUrl = _audioUrlController.text.trim();
    } else if (_hasLocalFile) {
      MoeToast.warning(widget.parentContext, '当前渠道不支持本地文件，请改用公网直链');
      return;
    } else if (_hasUrlInput) {
      MoeToast.warning(widget.parentContext, '当前渠道不支持公网直链，请改用本地文件');
      return;
    }

    setState(() {
      _submitting = true;
    });

    try {
      final result = await TtsVoiceCatalogService.createVoice(
        context: bindingContext,
        request: VoiceCreateRequest(
          name: name,
          audioBytes: audioBytes,
          fileName: fileName,
          audioUrl: requestAudioUrl,
          promptText: promptText.isEmpty ? null : promptText,
          targetModel: entry.modelId,
        ),
      );

      final binding = _extractBindingFromRemoteVoice(
        remoteVoice: result.voice,
        entry: entry,
        bindingContext: bindingContext,
      );
      _upsertBinding(binding);

      if (!mounted) return;
      final message = result.statusMessage?.trim();
      MoeToast.success(
        widget.parentContext,
        message == null || message.isEmpty
            ? '已生成 ${entry.providerName} 音色 ID'
            : message,
      );
    } catch (e) {
      final message = e is TtsProviderException ? e.message : '生成失败: $e';
      if (!mounted) return;
      MoeToast.error(widget.parentContext, message);
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
        });
      }
    }
  }

  Future<void> _addManualBinding() async {
    final entry = _selectedBindingEntry;
    final bindingContext = _selectedBindingContext;
    final manualVoiceId = _manualVoiceIdController.text.trim();
    if (entry == null) {
      MoeToast.warning(widget.parentContext, '请先选择渠道模型');
      return;
    }
    if (manualVoiceId.isEmpty) {
      MoeToast.warning(widget.parentContext, '请输入音色 ID');
      return;
    }

    final binding = VoiceChannelBinding(
      providerId: entry.providerId,
      providerName: entry.providerName,
      adapterId:
          bindingContext?.voiceProviderId ?? entry.voiceProviderId ?? entry.providerId,
      modelId: entry.modelId,
      remoteVoiceId: manualVoiceId,
      sourceKind: VoiceBindingSourceKind.manual,
    );
    _upsertBinding(binding);
    _manualVoiceIdController.clear();
    setState(() {});
    MoeToast.success(widget.parentContext, '已添加手动音色 ID');
  }

  void _removeBinding(VoiceChannelBinding binding) {
    setState(() {
      _bindings = _bindings.where((item) {
        return !(item.providerId == binding.providerId &&
            item.adapterId == binding.adapterId &&
            (item.modelId ?? '') == (binding.modelId ?? '') &&
            item.remoteVoiceId == binding.remoteVoiceId);
      }).toList();
    });
  }

  void _upsertBinding(VoiceChannelBinding binding) {
    final next = [..._bindings];
    final index = next.indexWhere((item) {
      final sameAdapter = item.normalizedAdapterId != null &&
          binding.normalizedAdapterId != null &&
          item.normalizedAdapterId == binding.normalizedAdapterId;
      final sameProvider = item.normalizedProviderId == binding.normalizedProviderId;
      return (sameAdapter || sameProvider) &&
          (item.modelId ?? '') == (binding.modelId ?? '');
    });
    if (index >= 0) {
      next[index] = binding;
    } else {
      next.add(binding);
    }
    setState(() {
      _bindings = next;
    });
  }

  VoiceChannelBinding _extractBindingFromRemoteVoice({
    required VoicePreset remoteVoice,
    required TtsAvailableModelEntry entry,
    required TtsProviderContext bindingContext,
  }) {
    final matchedBinding = remoteVoice.resolveBinding(
      providerId: entry.providerId,
      adapterId: bindingContext.voiceProviderId,
      modelId: entry.modelId,
    );
    if (matchedBinding != null) {
      return matchedBinding;
    }

    String? remoteVoiceId;
    for (final binding in remoteVoice.effectiveBindings) {
      final candidate = binding.remoteVoiceId.trim();
      if (candidate.isNotEmpty) {
        remoteVoiceId = candidate;
        break;
      }
    }
    remoteVoiceId ??= remoteVoice.aliyunVoiceId?.trim();
    remoteVoiceId ??= remoteVoice.siliconFlowVoiceUri?.trim();

    if (remoteVoiceId == null || remoteVoiceId.isEmpty) {
      throw TtsProviderException('渠道返回成功，但未解析到音色 ID');
    }

    return VoiceChannelBinding(
      providerId: entry.providerId,
      providerName: entry.providerName,
      adapterId:
          bindingContext.voiceProviderId ?? entry.voiceProviderId ?? entry.providerId,
      modelId: entry.modelId,
      remoteVoiceId: remoteVoiceId,
      status: remoteVoice.aliyunVoiceStatus,
      sourceKind: VoiceBindingSourceKind.remoteCreated,
    );
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      MoeToast.warning(widget.parentContext, '请输入音色名称');
      return;
    }
    if (!_hasReferenceAudio && _bindings.isEmpty) {
      MoeToast.warning(widget.parentContext, '请至少提供参考音频或添加一个渠道音色 ID');
      return;
    }

    setState(() {
      _submitting = true;
    });

    try {
      final existing = widget.preset;
      final audioUrl = _audioUrlController.text.trim();
      final promptText = _promptTextController.text.trim();
      final originalLocalPath = existing?.localAudioPath;

      final fallbackSourceType = _hasLocalFile
          ? VoiceSourceType.local
          : (_hasUrlInput
              ? VoiceSourceType.url
              : (existing?.sourceType ?? VoiceSourceType.url));

      var preset = VoicePreset(
        id: existing?.id,
        name: name,
        sourceType: fallbackSourceType,
        providerType: existing?.providerType ?? VoiceProviderType.custom,
        promptAudioUrl: audioUrl.isEmpty ? null : audioUrl,
        promptText: promptText.isEmpty ? null : promptText,
        emoText: existing?.emoText,
        useEmoText: existing?.useEmoText ?? false,
        source: existing?.source,
        isBuiltIn: existing?.isBuiltIn ?? false,
        localAudioPath: _hasLocalFile ? _localAudioPath : null,
      );
      preset = preset.copyWithBindings(_bindings);

      if (_isEdit) {
        await widget.notifier.updateVoicePreset(preset);
      } else {
        await widget.notifier.addVoicePreset(preset);
        await widget.notifier.selectVoicePreset(preset.id);
      }

      if (originalLocalPath != null &&
          originalLocalPath.isNotEmpty &&
          originalLocalPath != _localAudioPath) {
        _deleteFileIfNeeded(originalLocalPath);
      }

      if (!mounted) return;
      MoeToast.success(
        widget.parentContext,
        _isEdit ? '已保存音色与渠道绑定' : '已添加音色',
      );
      Navigator.of(context).pop();
    } catch (e) {
      final message = e is TtsProviderException ? e.message : '保存失败: $e';
      if (!mounted) return;
      MoeToast.error(widget.parentContext, message);
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final selectedEntry = _selectedBindingEntry;
    final selectedContext = _selectedBindingContext;
    final selectedCapabilities = _selectedBindingCapabilities;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle('音色名称', colors),
          const SizedBox(height: 8),
          MoeTextField(
            controller: _nameController,
            hint: '如：温柔女声',
            enabled: !_isBuiltIn && !_submitting,
          ),
          const SizedBox(height: 16),
          _buildSectionTitle('基础素材', colors),
          const SizedBox(height: 4),
          Text(
            '这份参考音频会被多个渠道复用；没有素材也能先保存手填的渠道音色 ID。',
            style: TextStyle(color: colors.muted, fontSize: 12),
          ),
          const SizedBox(height: 8),
          MoeTextField(
            controller: _audioUrlController,
            hint: 'https://example.com/voice.mp3',
            enabled: !_isBuiltIn && !_submitting && !_hasLocalFile,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          if (!_hasUrlInput && !_isBuiltIn)
            GestureDetector(
              onTap: _submitting ? null : _pickLocalFile,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: MoeG2Decoration(
                  radius: 8,
                  color: colors.muted.withValues(alpha: 0.1),
                  border: Border.all(
                    color: colors.muted.withValues(alpha: 0.2),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.upload_file, color: colors.muted, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      '选择本地音频文件',
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_hasLocalFile) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: MoeG2Decoration(
                radius: 8,
                color: colors.primary.withValues(alpha: 0.1),
                border: Border.all(
                  color: colors.primary.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.audio_file, color: colors.primary, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _localAudioFileName ?? '本地文件',
                      style: TextStyle(color: colors.text, fontSize: 14),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (!_isBuiltIn)
                    GestureDetector(
                      onTap: _submitting
                          ? null
                          : () {
                              _deleteFileIfNeeded(
                                _localAudioPath,
                                keepIfOriginal: true,
                              );
                              setState(() {
                                _localAudioPath = null;
                                _localAudioFileName = null;
                              });
                            },
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(Icons.close, color: colors.muted, size: 18),
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          _buildSectionTitle('参考文本（选填）', colors),
          const SizedBox(height: 4),
          Text(
            '与参考音频对应的文本。部分渠道在在线创建音色时会要求必填。',
            style: TextStyle(color: colors.muted, fontSize: 12),
          ),
          const SizedBox(height: 8),
          MoeTextField(
            controller: _promptTextController,
            hint: '输入音频中说的话...',
            maxLines: 2,
            enabled: !_isBuiltIn && !_submitting,
          ),
          const SizedBox(height: 16),
          _buildSectionTitle('渠道绑定', colors),
          const SizedBox(height: 4),
          Text(
            '先选渠道模型，再在线生成对应音色，或手动填写该渠道的音色 ID。',
            style: TextStyle(color: colors.muted, fontSize: 12),
          ),
          const SizedBox(height: 8),
          if (widget.availableModels.isEmpty)
            _buildInfoCard(
              icon: Icons.key_off_outlined,
              text: '当前没有可用渠道。请先在模型设置里配置带 API Key 的 TTS 模型。',
              color: colors.muted,
            )
          else ...[
            GestureDetector(
              onTap:
                  _isBuiltIn || _submitting ? null : _showBindingModelSelector,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: MoeG2Decoration(
                  radius: 8,
                  color: colors.muted.withValues(alpha: 0.08),
                  border: Border.all(
                    color: colors.muted.withValues(alpha: 0.18),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.hub_outlined, color: colors.primary, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            selectedEntry?.providerName ?? '选择渠道模型',
                            style: TextStyle(
                              color: colors.text,
                              fontSize: 14,
                              fontWeight: MoeFontWeights.emphasis,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            selectedEntry == null
                                ? '仅显示已配置 key 的 TTS 模型'
                                : selectedEntry.displayName,
                            style: TextStyle(
                              color: colors.muted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: colors.muted, size: 20),
                  ],
                ),
              ),
            ),
            if (selectedEntry != null) ...[
              const SizedBox(height: 12),
              _buildInfoCard(
                icon: Icons.info_outline,
                text: _buildBindingCapabilityText(
                  entry: selectedEntry,
                  capabilities: selectedCapabilities,
                  bindingContext: selectedContext,
                ),
                color: colors.primary,
              ),
            ],
            if (selectedCapabilities?.hasExpirationPolicy == true &&
                selectedCapabilities?.expirationDescription != null) ...[
              const SizedBox(height: 12),
              _buildInfoCard(
                icon: Icons.schedule_outlined,
                text: selectedCapabilities!.expirationDescription!,
                color: colors.primary,
              ),
            ],
            const SizedBox(height: 12),
            MoeTextField(
              controller: _manualVoiceIdController,
              hint: '手动填写渠道音色 ID',
              enabled: !_isBuiltIn && !_submitting,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: MoeSecondaryButton(
                    label: '生成渠道音色',
                    icon: Icons.auto_awesome,
                    enabled: _canCreateBinding,
                    onPressed: _canCreateBinding
                        ? _createBindingForSelectedChannel
                        : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: MoePrimaryButton(
                    label: '手填音色 ID',
                    icon: Icons.edit_outlined,
                    enabled: !_isBuiltIn && !_submitting,
                    onPressed:
                        _isBuiltIn || _submitting ? null : _addManualBinding,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          _buildBindingsSection(colors),
          const SizedBox(height: 24),
          if (_isBuiltIn)
            MoePrimaryButton(
              label: '关闭',
              onPressed: () => Navigator.of(context).pop(),
            )
          else
            Row(
              children: [
                Expanded(
                  child: MoeSecondaryButton(
                    label: '取消',
                    onPressed: _submitting
                        ? null
                        : () {
                            if (!_isEdit) {
                              _deleteFileIfNeeded(_localAudioPath);
                            }
                            Navigator.of(context).pop();
                          },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: MoePrimaryButton(
                    label: _submitting ? '保存中...' : (_isEdit ? '保存' : '添加'),
                    onPressed: _submitting ? null : _save,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildBindingsSection(MoeColors colors) {
    if (_bindings.isEmpty) {
      return _buildInfoCard(
        icon: Icons.link_off_outlined,
        text: '当前还没有渠道音色绑定。你可以先保存基础素材，之后再回来补渠道 ID。',
        color: colors.muted,
      );
    }

    return Column(
      children: _bindings.map((binding) {
        final status = binding.status?.trim();
        final sourceKind = _describeSourceKind(binding.sourceKind);
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: MoeG2Decoration(
              radius: 8,
              color: colors.primary.withValues(alpha: 0.08),
              border: Border.all(
                color: colors.primary.withValues(alpha: 0.16),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.link, color: colors.primary, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        binding.providerName,
                        style: TextStyle(
                          color: colors.text,
                          fontSize: 14,
                          fontWeight: MoeFontWeights.emphasis,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '模型: ${binding.modelId ?? '未指定'}',
                        style: TextStyle(color: colors.muted, fontSize: 12),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '音色 ID: ${binding.remoteVoiceId}',
                        style: TextStyle(color: colors.muted, fontSize: 12),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '来源: $sourceKind',
                        style: TextStyle(color: colors.muted, fontSize: 12),
                      ),
                      if (status != null && status.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          '状态: $status',
                          style: TextStyle(color: colors.muted, fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                ),
                if (!_isBuiltIn)
                  GestureDetector(
                    onTap: _submitting ? null : () => _removeBinding(binding),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Icons.delete_outline,
                        color: colors.muted,
                        size: 18,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  String _buildBindingCapabilityText({
    required TtsAvailableModelEntry entry,
    required TtsCapabilities? capabilities,
    required TtsProviderContext? bindingContext,
  }) {
    final parts = <String>['${entry.providerName} / ${entry.displayName}'];

    if (bindingContext == null || !bindingContext.hasVoiceProvider) {
      parts.add('当前渠道暂不支持在线创建，只能手填音色 ID');
      return parts.join(' · ');
    }

    if (capabilities != null) {
      final uploadModes = <String>[];
      if (capabilities.canUploadUrl) uploadModes.add('公网直链');
      if (capabilities.canUploadFile) uploadModes.add('本地文件');
      if (uploadModes.isNotEmpty) {
        parts.add('支持 ${uploadModes.join(' / ')}');
      }
      if (capabilities.needsPromptText) {
        parts.add('生成时需要参考文本');
      }
      if (capabilities.needsApproval) {
        parts.add('创建后需审核');
      }
    }

    parts.add(bindingContext.hasApiKey ? '可在线创建' : '缺少 API Key');
    return parts.join(' · ');
  }

  String _describeSourceKind(VoiceBindingSourceKind sourceKind) {
    switch (sourceKind) {
      case VoiceBindingSourceKind.remoteCreated:
        return '在线创建';
      case VoiceBindingSourceKind.manual:
        return '手动填写';
      case VoiceBindingSourceKind.imported:
        return '远端导入';
      case VoiceBindingSourceKind.legacy:
        return '旧字段迁移';
    }
  }

  Widget _buildSectionTitle(String text, MoeColors colors) {
    return Text(
      text,
      style: TextStyle(
        color: colors.text,
        fontSize: 14,
        fontWeight: MoeFontWeights.emphasis,
      ),
    );
  }

  Widget _buildInfoCard({
    required IconData icon,
    required String text,
    required Color color,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: MoeG2Decoration(
        radius: 8,
        color: color.withValues(alpha: 0.08),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: color, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  static String? _extractFileName(String? path) {
    if (path == null || path.isEmpty) return null;
    return path.split('/').last.split('\\').last;
  }

  void _deleteFileIfNeeded(String? path, {bool keepIfOriginal = false}) {
    if (path == null || path.isEmpty) return;
    if (keepIfOriginal && path == widget.preset?.localAudioPath) {
      return;
    }
    try {
      File(path).deleteSync();
    } catch (_) {}
  }
}

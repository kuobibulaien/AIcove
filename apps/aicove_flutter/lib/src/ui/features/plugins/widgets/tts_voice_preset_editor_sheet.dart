library;

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../features/plugins/plugin_providers.dart';
import '../../../../features/plugins/tts/providers/tts_voice_provider.dart';
import '../../../../features/plugins/tts/tts_config.dart';
import '../../../../features/plugins/tts/tts_provider_context.dart';
import '../../../../features/plugins/tts/tts_voice_catalog_service.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

Future<void> showTtsVoicePresetEditorSheet({
  required BuildContext context,
  required TtsPluginConfigNotifier notifier,
  required TtsProviderContext providerContext,
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
      colors: colors,
      preset: preset,
    ),
  );
}

class _TtsVoicePresetEditorSheetContent extends StatefulWidget {
  final BuildContext parentContext;
  final TtsPluginConfigNotifier notifier;
  final TtsProviderContext providerContext;
  final MoeColors colors;
  final VoicePreset? preset;

  const _TtsVoicePresetEditorSheetContent({
    required this.parentContext,
    required this.notifier,
    required this.providerContext,
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
  String? _localAudioPath;
  String? _localAudioFileName;
  bool _submitting = false;

  bool get _isEdit => widget.preset != null;

  bool get _isBuiltIn => widget.preset?.isBuiltIn ?? false;

  TtsCapabilities? get _capabilities => widget.providerContext.capabilities;

  bool get _canUploadFile => _capabilities?.canUploadFile ?? true;

  bool get _canUploadUrl => _capabilities?.canUploadUrl ?? true;

  bool get _needsPromptText => _capabilities?.needsPromptText ?? false;

  @override
  void initState() {
    super.initState();
    final preset = widget.preset;
    _nameController = TextEditingController(text: preset?.name ?? '');
    _audioUrlController =
        TextEditingController(text: preset?.promptAudioUrl ?? '');
    _promptTextController =
        TextEditingController(text: preset?.promptText ?? '');
    _localAudioPath = preset?.localAudioPath;
    _localAudioFileName = _extractFileName(_localAudioPath);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _audioUrlController.dispose();
    _promptTextController.dispose();
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

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      MoeToast.warning(widget.parentContext, '请输入音色名称');
      return;
    }

    final audioUrl = _audioUrlController.text.trim();
    final promptText = _promptTextController.text.trim();
    final hasUrlInput = audioUrl.isNotEmpty;
    final hasFileInput = _localAudioPath != null && _localAudioPath!.isNotEmpty;

    if (!hasUrlInput && !hasFileInput) {
      MoeToast.warning(widget.parentContext, '请提供参考音频');
      return;
    }
    if (_needsPromptText && promptText.isEmpty) {
      MoeToast.warning(widget.parentContext, '当前渠道要求填写参考文本');
      return;
    }

    final shouldCreateRemote = widget.providerContext.canManageRemoteVoices &&
        (!_isEdit || _didAudioMaterialChange());

    setState(() {
      _submitting = true;
    });

    try {
      VoicePreset savedPreset;
      String successMessage = _isEdit ? '已保存' : '已添加';

      if (shouldCreateRemote) {
        final remoteVoice = await _createRemoteVoice(
          name: name,
          audioUrl: hasUrlInput ? audioUrl : null,
          promptText: promptText.isEmpty ? null : promptText,
        );
        savedPreset = _composePreset(
          name: name,
          audioUrl: hasUrlInput ? audioUrl : null,
          localAudioPath: hasFileInput ? _localAudioPath : null,
          promptText: promptText.isEmpty ? null : promptText,
          remoteVoice: remoteVoice.voice,
        );
        if (remoteVoice.statusMessage != null &&
            remoteVoice.statusMessage!.trim().isNotEmpty) {
          successMessage = remoteVoice.statusMessage!.trim();
        }
      } else {
        savedPreset = _composePreset(
          name: name,
          audioUrl: hasUrlInput ? audioUrl : null,
          localAudioPath: hasFileInput ? _localAudioPath : null,
          promptText: promptText.isEmpty ? null : promptText,
        );
        if (!widget.providerContext.canManageRemoteVoices &&
            widget.providerContext.hasConfiguredProvider) {
          successMessage = '已保存素材，后续补齐渠道配置后可继续使用';
        }
      }

      if (_isEdit) {
        await widget.notifier.updateVoicePreset(savedPreset);
      } else {
        await widget.notifier.addVoicePreset(savedPreset);
        await widget.notifier.selectVoicePreset(savedPreset.id);
      }

      if (!mounted) return;
      final parentContext = widget.parentContext;
      if (!parentContext.mounted) return;
      if (shouldCreateRemote && savedPreset.aliyunVoiceStatus == 'DEPLOYING') {
        MoeToast.warning(parentContext, successMessage);
      } else {
        MoeToast.success(parentContext, successMessage);
      }
      Navigator.of(context).pop();
    } catch (e) {
      final message = e is TtsProviderException ? e.message : '保存失败: $e';
      final parentContext = widget.parentContext;
      if (!parentContext.mounted) return;
      MoeToast.error(parentContext, message);
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
        });
      }
    }
  }

  Future<VoiceCreateResult> _createRemoteVoice({
    required String name,
    required String? audioUrl,
    required String? promptText,
  }) async {
    Uint8List? audioBytes;
    String? fileName;
    if (_localAudioPath != null && _localAudioPath!.isNotEmpty) {
      final file = File(_localAudioPath!);
      audioBytes = await file.readAsBytes();
      fileName = _extractFileName(_localAudioPath);
    }

    return TtsVoiceCatalogService.createVoice(
      context: widget.providerContext,
      request: VoiceCreateRequest(
        name: name,
        audioBytes: audioBytes,
        fileName: fileName,
        audioUrl: audioUrl,
        promptText: promptText,
        targetModel: widget.providerContext.selectedModelId,
      ),
    );
  }

  VoicePreset _composePreset({
    required String name,
    required String? audioUrl,
    required String? localAudioPath,
    required String? promptText,
    VoicePreset? remoteVoice,
  }) {
    final fallbackSourceType =
        localAudioPath != null ? VoiceSourceType.local : VoiceSourceType.url;
    final existing = widget.preset;

    return VoicePreset(
      id: existing?.id ?? remoteVoice?.id,
      name: name,
      sourceType: remoteVoice?.sourceType ?? fallbackSourceType,
      providerType: remoteVoice?.providerType ??
          existing?.providerType ??
          VoiceProviderType.custom,
      promptAudioUrl: audioUrl ?? remoteVoice?.promptAudioUrl,
      promptText: promptText,
      source: remoteVoice?.source ?? existing?.source,
      isBuiltIn: existing?.isBuiltIn ?? false,
      aliyunVoiceId: remoteVoice != null
          ? remoteVoice.aliyunVoiceId
          : existing?.aliyunVoiceId,
      aliyunTargetModel: remoteVoice != null
          ? remoteVoice.aliyunTargetModel
          : existing?.aliyunTargetModel,
      aliyunVoiceStatus: remoteVoice != null
          ? remoteVoice.aliyunVoiceStatus
          : existing?.aliyunVoiceStatus,
      siliconFlowVoiceUri: remoteVoice != null
          ? remoteVoice.siliconFlowVoiceUri
          : existing?.siliconFlowVoiceUri,
      siliconFlowModel: remoteVoice != null
          ? remoteVoice.siliconFlowModel
          : existing?.siliconFlowModel,
      localAudioPath: localAudioPath,
    );
  }

  bool _didAudioMaterialChange() {
    final originalUrl = widget.preset?.promptAudioUrl?.trim() ?? '';
    final currentUrl = _audioUrlController.text.trim();
    final originalPath = widget.preset?.localAudioPath?.trim() ?? '';
    final currentPath = _localAudioPath?.trim() ?? '';
    final originalPrompt = widget.preset?.promptText?.trim() ?? '';
    final currentPrompt = _promptTextController.text.trim();
    return originalUrl != currentUrl ||
        originalPath != currentPath ||
        originalPrompt != currentPrompt;
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final hasUrl = _audioUrlController.text.trim().isNotEmpty;
    final hasLocalFile = _localAudioPath != null && _localAudioPath!.isNotEmpty;
    final audioHint = switch ((_canUploadUrl, _canUploadFile)) {
      (true, true) => '支持公网直链或本地文件（二选一）',
      (true, false) => '当前渠道只支持公网直链',
      (false, true) => '当前渠道只支持本地文件上传',
      (false, false) => '当前渠道暂不支持上传参考音频',
    };

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '音色名称',
            style: TextStyle(
              color: colors.text,
              fontSize: 14,
              fontWeight: MoeFontWeights.emphasis,
            ),
          ),
          const SizedBox(height: 8),
          MoeTextField(
            controller: _nameController,
            hint: '如：温柔女声',
            enabled: !_isBuiltIn && !_submitting,
          ),
          const SizedBox(height: 16),
          Text(
            '参考音频',
            style: TextStyle(
              color: colors.text,
              fontSize: 14,
              fontWeight: MoeFontWeights.emphasis,
            ),
          ),
          const SizedBox(height: 4),
          Text(audioHint, style: TextStyle(color: colors.muted, fontSize: 12)),
          const SizedBox(height: 8),
          if (_canUploadUrl) ...[
            MoeTextField(
              controller: _audioUrlController,
              hint: 'https://example.com/voice.mp3',
              enabled: !_isBuiltIn && !_submitting && !hasLocalFile,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
          ],
          if (_canUploadFile && !hasUrl && !_isBuiltIn)
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
          if (hasLocalFile) ...[
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
          Text(
            _needsPromptText ? '参考文本（必填）' : '参考文本（选填）',
            style: TextStyle(
              color: colors.text,
              fontSize: 14,
              fontWeight: MoeFontWeights.emphasis,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '与参考音频对应的文本，可提升复刻效果',
            style: TextStyle(color: colors.muted, fontSize: 12),
          ),
          const SizedBox(height: 8),
          MoeTextField(
            controller: _promptTextController,
            hint: '输入音频中说的话...',
            maxLines: 2,
            enabled: !_isBuiltIn && !_submitting,
          ),
          if (_capabilities?.hasExpirationPolicy == true &&
              _capabilities?.expirationDescription != null) ...[
            const SizedBox(height: 16),
            _buildInfoCard(
              icon: Icons.schedule_outlined,
              text: _capabilities!.expirationDescription!,
              color: colors.primary,
            ),
          ],
          if (widget.preset != null) ...[
            const SizedBox(height: 16),
            _buildRemoteBindingCard(colors),
          ],
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

  Widget _buildRemoteBindingCard(MoeColors colors) {
    final preset = widget.preset;
    if (preset == null) {
      return const SizedBox.shrink();
    }

    final lines = <String>[];
    var title = '远端音色信息';

    if (preset.aliyunVoiceId != null && preset.aliyunVoiceId!.isNotEmpty) {
      title = '远端音色 ID';
      lines.add('ID: ${preset.aliyunVoiceId}');
      if (preset.aliyunTargetModel != null &&
          preset.aliyunTargetModel!.isNotEmpty) {
        lines.add('模型: ${preset.aliyunTargetModel}');
      }
      if (preset.aliyunVoiceStatus != null &&
          preset.aliyunVoiceStatus!.isNotEmpty) {
        lines.add('状态: ${preset.aliyunVoiceStatus}');
      }
    } else if (preset.siliconFlowVoiceUri != null &&
        preset.siliconFlowVoiceUri!.isNotEmpty) {
      title = '远端音色 URI';
      lines.add('URI: ${preset.siliconFlowVoiceUri}');
      if (preset.siliconFlowModel != null &&
          preset.siliconFlowModel!.isNotEmpty) {
        lines.add('模型: ${preset.siliconFlowModel}');
      }
    } else if (!preset.isBuiltIn &&
        ((preset.promptAudioUrl?.isNotEmpty ?? false) ||
            (preset.localAudioPath?.isNotEmpty ?? false))) {
      lines.add('当前仅保存了音色素材，远端音色会在需要时再创建。');
    }

    if (lines.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: MoeG2Decoration(
        radius: 8,
        color: colors.primary.withValues(alpha: 0.1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.cloud_done, color: colors.primary, size: 16),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  color: colors.primary,
                  fontSize: 13,
                  fontWeight: MoeFontWeights.emphasis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ...lines.map(
            (line) => Text(
              line,
              style: TextStyle(color: colors.muted, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCard({
    required IconData icon,
    required String text,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: MoeG2Decoration(
        radius: 8,
        color: color.withValues(alpha: 0.08),
      ),
      child: Row(
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

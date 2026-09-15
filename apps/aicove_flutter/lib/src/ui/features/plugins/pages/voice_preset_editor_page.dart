import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:aicove_flutter/src/ui/shared/animations/parallax_slide_page_route.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/models/message_block.dart';
import '../../../../features/chat/presentation/widgets/audio_player_widget.dart';
import '../../../../features/plugins/tts/tts_available_models.dart';
import '../../../../features/plugins/tts/tts_config.dart';
import '../../../../features/plugins/tts/tts_provider_context.dart';
import '../../../../features/plugins/tts/voice_preset_application.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import '../../settings/pages/model_list_page.dart';

class VoicePresetEditorPage extends ConsumerStatefulWidget {
  const VoicePresetEditorPage({super.key, this.preset});
  final VoicePreset? preset;
  @override
  ConsumerState<VoicePresetEditorPage> createState() =>
      _VoicePresetEditorPageState();
}

class _VoicePresetEditorPageState extends ConsumerState<VoicePresetEditorPage>
    with MoeAutoSaveState<VoicePresetEditorPage> {
  final _form = GlobalKey<FormState>();
  late final VoicePreset _original;
  late final TextEditingController _name,
      _voice,
      _url,
      _text,
      _emotion,
      _chunk,
      _prompt;
  final _sample = TextEditingController(text: '你好，很高兴见到你。今天想聊些什么？');
  String? _provider, _model, _localPath, _audio, _error;
  List<VoiceChannelBinding> _bindings = [];
  VoiceSourceType _source = VoiceSourceType.preset;
  double _speed = 1;
  int _frequency = 60;
  bool _busy = false, _useEmotion = false;

  @override
  void initState() {
    super.initState();
    _original = widget.preset ?? VoicePreset(name: '');
    final synthesis = _original.synthesis;
    _name = TextEditingController(text: _original.name);
    _voice = TextEditingController(text: synthesis?.voiceId ?? '');
    _url = TextEditingController(text: _original.promptAudioUrl ?? '');
    _text = TextEditingController(text: _original.promptText ?? '');
    _emotion = TextEditingController(text: _original.emoText ?? '');
    _chunk = TextEditingController(
      text: '${synthesis?.maxCharsPerChunk ?? 20}',
    );
    _provider = synthesis?.providerId;
    _model = synthesis?.modelId;
    _localPath = _original.localAudioPath;
    _speed = (synthesis?.speed ?? 1).clamp(0.5, 2);
    _frequency = (synthesis?.voiceFrequency ?? 60).clamp(0, 100);
    _prompt = TextEditingController(
      text: synthesis?.systemPromptTemplate ?? '',
    );
    _bindings = _original.bindings;
    _useEmotion = _original.useEmoText;
    _source = synthesis?.voiceId?.isNotEmpty == true
        ? VoiceSourceType.preset
        : _localPath?.isNotEmpty == true
        ? VoiceSourceType.local
        : _url.text.isNotEmpty
        ? VoiceSourceType.url
        : VoiceSourceType.preset;
    autoSave.configure(
      save: _save,
      snapshot: () => moeAutoSaveSignature(_draft().toJson()),
      fields: [_name, _voice, _url, _text, _emotion, _chunk, _prompt],
    );
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _voice,
      _url,
      _text,
      _emotion,
      _chunk,
      _sample,
      _prompt,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  VoicePreset _draft() => VoicePreset(
    id: _original.id,
    name: _name.text.trim(),
    sourceType: _source,
    providerType: _original.providerType,
    isBuiltIn: _original.isBuiltIn,
    source: _original.source,
    synthesis: _provider == null || _model == null
        ? null
        : VoiceSynthesisSettings(
            providerId: _provider!,
            modelId: _model!,
            voiceId: _source == VoiceSourceType.preset
                ? _voice.text.trim()
                : null,
            speed: _speed,
            voiceFrequency: _frequency,
            systemPromptTemplate: _prompt.text.trim().isEmpty
                ? null
                : _prompt.text,
            maxCharsPerChunk: int.tryParse(_chunk.text) ?? 0,
          ),
    promptAudioUrl: _source == VoiceSourceType.url ? _url.text.trim() : null,
    localAudioPath: _source == VoiceSourceType.local ? _localPath : null,
    promptText: _text.text.trim(),
    emoText: _emotion.text.trim(),
    useEmoText: _useEmotion,
    bindings: _bindings,
    aliyunVoiceId: _original.aliyunVoiceId,
    aliyunTargetModel: _original.aliyunTargetModel,
    aliyunVoiceStatus: _original.aliyunVoiceStatus,
    siliconFlowVoiceUri: _original.siliconFlowVoiceUri,
    siliconFlowModel: _original.siliconFlowModel,
  );

  Future<void> _work(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _validate() {
    if (!_form.currentState!.validate()) return false;
    if (_provider == null || _model == null) {
      setState(() => _error = '请先选择供应商与模型');
      return false;
    }
    if (_source == VoiceSourceType.local &&
        (_localPath == null || _localPath!.isEmpty)) {
      setState(() => _error = '请选择参考音频文件');
      return false;
    }
    final context = TtsProviderContext.resolveForSelection(
      config: TtsConfig(),
      settings: ref.read(appSettingsProvider).valueOrNull,
      providerId: _provider!,
      modelId: _model!,
    );
    if (_source != VoiceSourceType.preset &&
        context.capabilities?.needsPromptText == true &&
        _text.text.trim().isEmpty) {
      setState(() => _error = '此供应商需要参考音频对应的文字');
      return false;
    }
    return true;
  }

  Future<void> _save() async {
    if (!_validate()) throw FormatException(_error ?? '请填写有效的音色预设');
    await ref.read(voicePresetApplicationProvider).save(_draft());
  }

  Future<void> _pickModel(List<TtsAvailableModelEntry> models) async {
    String query = '';
    final selected = await showModalBottomSheet<TtsAvailableModelEntry>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: 0.85,
        child: SafeArea(
          child: StatefulBuilder(
            builder: (context, update) {
              final matches = models
                  .where(
                    (m) => '${m.providerName} ${m.displayName}'
                        .toLowerCase()
                        .contains(query.toLowerCase()),
                  )
                  .toList();
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: MoeSearchField(
                      padding: EdgeInsets.zero,
                      hintText: '搜索供应商或模型',
                      onChanged: (value) => update(() => query = value),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: matches.length,
                      itemBuilder: (context, index) {
                        final entry = matches[index];
                        return ListTile(
                          title: Text(entry.displayName),
                          subtitle: Text(entry.providerName),
                          onTap: () => Navigator.pop(context, entry),
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    if (selected.providerId == _provider && selected.modelId == _model) return;
    setState(() {
      _provider = selected.providerId;
      _model = selected.modelId;
      _voice.clear();
      _bindings = [];
      _audio = null;
      _error = '已切换渠道或模型，请重新选择音色 ID；参考素材保留。';
    });
  }

  Future<void> _browse() async {
    if (_provider == null || _model == null) return;
    final provider = _provider!, model = _model!;
    await _work(() async {
      final result = await ref
          .read(voicePresetApplicationProvider)
          .catalog(provider, model);
      if (!mounted) return;
      final voices = [...result.presetVoices, ...result.userVoices];
      String query = '';
      final selected = await showModalBottomSheet<VoicePreset>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => FractionallySizedBox(
          heightFactor: 0.85,
          child: SafeArea(
            child: StatefulBuilder(
              builder: (context, update) {
                final matches = voices
                    .where(
                      (v) =>
                          '${v.name} ${v.bindings.map((b) => b.remoteVoiceId).join(' ')}'
                              .toLowerCase()
                              .contains(query.toLowerCase()),
                    )
                    .toList();
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: MoeSearchField(
                        padding: EdgeInsets.zero,
                        hintText: '搜索当前供应商音色',
                        onChanged: (value) => update(() => query = value),
                      ),
                    ),
                    if (matches.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('没有找到音色，可返回手动填写音色 ID'),
                      ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: matches.length,
                        itemBuilder: (context, index) {
                          final voice = matches[index];
                          return ListTile(
                            title: Text(voice.name),
                            subtitle: Text(
                              voice.bindings
                                  .map((b) => b.remoteVoiceId)
                                  .join(' · '),
                            ),
                            onTap: () => Navigator.pop(context, voice),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
      if (!mounted || selected == null) return;
      final binding = selected.bindings
          .where((b) => b.providerId == provider)
          .firstOrNull;
      if (binding == null) throw StateError('音色没有当前渠道的绑定，请手动填写 ID');
      setState(() {
        _voice.text = binding.remoteVoiceId;
        if (_name.text.trim().isEmpty) _name.text = selected.name;
        _bindings = [
          VoiceChannelBinding(
            providerId: provider,
            providerName: binding.providerName,
            modelId: model,
            adapterId: binding.adapterId,
            remoteVoiceId: binding.remoteVoiceId,
            status: binding.status,
            sourceKind: binding.sourceKind,
          ),
        ];
        _source = VoiceSourceType.preset;
        _audio = null;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final models = buildConfiguredTtsModels(settings);
    final entry = models
        .where((m) => m.providerId == _provider && m.modelId == _model)
        .firstOrNull;
    final providerContext = _provider == null || _model == null
        ? null
        : TtsProviderContext.resolveForSelection(
            config: TtsConfig(),
            settings: settings,
            providerId: _provider!,
            modelId: _model!,
          );
    final canBrowse = providerContext?.hasVoiceProvider == true;
    final capabilities = providerContext?.capabilities;
    final colors = context.moeColors;
    final canCreate =
        capabilities?.canUploadFile == true ||
        capabilities?.canUploadUrl == true;
    final format = providerContext?.requestFormat;
    final canLocal =
        capabilities?.canUploadFile == true ||
        format == 'siliconflow_indextts' ||
        format == 'aliyun_qwen_tts';
    final canUrl =
        capabilities?.canUploadUrl == true ||
        format == 'siliconflow_indextts' ||
        format == 'aliyun_qwen_tts';
    return autoSavePage(
      MoePageScaffold(
        backgroundColor: colors.surface,
        appBar: MoeAppBar(
          title: widget.preset == null ? '新建音色预设' : '编辑音色预设',
          showBackButton: true,
          actions: [
            IconButton(
              tooltip: '管理供应商',
              icon: const Icon(Icons.cloud_outlined),
              onPressed: () => Navigator.of(
                context,
              ).push(ParallaxSlidePageRoute(page: const ModelListPage())),
            ),
          ],
        ),
        body: SafeArea(
          child: MoeSettingsContent(
            child: Form(
              key: _form,
              child: ListView(
                padding: MoeSettingsLayout.verticalListPadding,
                children: [
                  if (_busy) const LinearProgressIndicator(),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                      child: Text(
                        _error!,
                        style: TextStyle(color: colors.primary),
                      ),
                    ),
                  AbsorbPointer(
                    absorbing: _busy,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        MoeSettingsGroup(
                          title: '基本信息',
                          titleFirst: true,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                              child: TextFormField(
                                controller: _name,
                                decoration: const InputDecoration(
                                  labelText: '预设名称',
                                  hintText: '例如：纳西妲 · 温柔',
                                ),
                                validator: (v) =>
                                    v?.trim().isEmpty != false ? '请填写名称' : null,
                              ),
                            ),
                            MoeSettingsRow(
                              label: '供应商与模型',
                              subtitle: entry == null
                                  ? (_provider == null
                                        ? '请选择已配置的语音模型'
                                        : '$_provider · $_model（检查渠道配置）')
                                  : '${entry.providerName}\n${entry.displayName}',
                              onTap: () => _pickModel(models),
                              showDivider: false,
                            ),
                            if (models.isEmpty)
                              const Padding(
                                padding: EdgeInsets.fromLTRB(12, 4, 12, 10),
                                child: Text('暂无可用语音模型：请先在供应商管理配置密钥，并将模型标记为语音。'),
                              ),
                          ],
                        ),
                        const SizedBox(height: MoeSettingsLayout.sectionGap),
                        MoeSettingsGroup(
                          title: '音色来源',
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                              child: Wrap(
                                spacing: 8,
                                children: [
                                  for (final value in VoiceSourceType.values)
                                    MoeButtonSurface(
                                      radius: 999,
                                      child: ChoiceChip(
                                        label: Text(switch (value) {
                                          VoiceSourceType.preset => '音色 ID',
                                          VoiceSourceType.url => '音频链接',
                                          VoiceSourceType.local => '音频文件',
                                        }),
                                        selected: _source == value,
                                        onSelected:
                                            (value == VoiceSourceType.local &&
                                                    !canLocal) ||
                                                (value == VoiceSourceType.url &&
                                                    !canUrl)
                                            ? null
                                            : (_) => setState(() {
                                                _source = value;
                                                _audio = null;
                                              }),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            if (_source == VoiceSourceType.preset) ...[
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  4,
                                  12,
                                  8,
                                ),
                                child: TextFormField(
                                  controller: _voice,
                                  decoration: const InputDecoration(
                                    labelText: '供应商音色 ID',
                                    hintText: '不是预设名称',
                                  ),
                                  validator: (v) => v?.trim().isEmpty != false
                                      ? '请填写或浏览选择音色 ID'
                                      : null,
                                ),
                              ),
                              if (canBrowse)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    0,
                                    12,
                                    8,
                                  ),
                                  child: TextButton(
                                    onPressed: _browse,
                                    child: const Text('浏览此供应商的音色'),
                                  ),
                                ),
                              if (_bindings.any(
                                (b) =>
                                    b.status != null &&
                                    b.status!.isNotEmpty &&
                                    b.status != 'OK',
                              ))
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    0,
                                    12,
                                    8,
                                  ),
                                  child: Text(
                                    '音色状态：${_bindings.map((b) => b.status ?? '').join(' ')}；审核未完成时暂不能发声',
                                  ),
                                ),
                            ] else ...[
                              if (_source == VoiceSourceType.url)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    4,
                                    12,
                                    8,
                                  ),
                                  child: TextFormField(
                                    controller: _url,
                                    decoration: const InputDecoration(
                                      labelText: '参考音频链接',
                                      hintText: 'https://...',
                                    ),
                                    validator: (v) {
                                      final uri = Uri.tryParse(v?.trim() ?? '');
                                      return uri == null ||
                                              ![
                                                'http',
                                                'https',
                                              ].contains(uri.scheme) ||
                                              uri.host.isEmpty
                                          ? '请填写有效的音频链接'
                                          : null;
                                    },
                                  ),
                                ),
                              if (_source == VoiceSourceType.local) ...[
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    4,
                                    12,
                                    4,
                                  ),
                                  child: Text(
                                    _localPath == null
                                        ? '尚未选择文件'
                                        : _localPath!.split('/').last,
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    0,
                                    12,
                                    8,
                                  ),
                                  child: OutlinedButton(
                                    onPressed: () => _work(() async {
                                      final picked = await FilePicker.platform
                                          .pickFiles(
                                            type: FileType.custom,
                                            allowedExtensions: [
                                              'mp3',
                                              'wav',
                                              'm4a',
                                              'flac',
                                              'ogg',
                                              'aac',
                                            ],
                                          );
                                      final path = picked?.files.single.path;
                                      if (path == null || !mounted) return;
                                      final saved = await ref
                                          .read(voicePresetApplicationProvider)
                                          .importAudio(path);
                                      if (mounted) {
                                        setState(() {
                                          _localPath = saved;
                                          _audio = null;
                                        });
                                      }
                                    }),
                                    child: const Text('选择音频文件'),
                                  ),
                                ),
                              ],
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  4,
                                  12,
                                  8,
                                ),
                                child: TextFormField(
                                  controller: _text,
                                  maxLines: 3,
                                  decoration: const InputDecoration(
                                    labelText: '参考音频对应的文字',
                                    helperText: '需要参考文本的模型请填写完整、准确的内容',
                                    helperMaxLines: 4,
                                  ),
                                ),
                              ),
                              if (canCreate)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    0,
                                    12,
                                    8,
                                  ),
                                  child: TextButton(
                                    onPressed: () {
                                      if (!_validate()) return;
                                      _work(() async {
                                        final confirmed =
                                            await showMeoTalkDialog(
                                              context: context,
                                              title: '创建云端音色',
                                              content: const Text(
                                                '参考音频将发送到此供应商，可能产生费用。继续吗？',
                                              ),
                                              confirmText: '创建',
                                            );
                                        if (confirmed != true || !mounted) {
                                          return;
                                        }
                                        final created = await ref
                                            .read(
                                              voicePresetApplicationProvider,
                                            )
                                            .createRemote(_draft());
                                        if (mounted) {
                                          setState(() {
                                            _bindings = created.bindings;
                                            _voice.text =
                                                created.synthesis!.voiceId!;
                                            _source = VoiceSourceType.preset;
                                          });
                                        }
                                      });
                                    },
                                    child: const Text('用参考音频创建云端音色'),
                                  ),
                                ),
                              const Padding(
                                padding: EdgeInsets.fromLTRB(12, 0, 12, 10),
                                child: Text(
                                  '支持参考音频的模型可直接试听；其他模型请先创建云端音色，再使用返回的音色 ID。',
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: MoeSettingsLayout.sectionGap),
                        MoeSettingsGroup(
                          title: '朗读参数',
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                              child: Text('语速 ${_speed.toStringAsFixed(1)}×'),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              child: MoeSlider(
                                value: _speed,
                                min: 0.5,
                                max: 2,
                                divisions: 15,
                                onChanged: (v) => setState(() => _speed = v),
                              ),
                            ),
                            ExpansionTile(
                              tilePadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              childrenPadding: const EdgeInsets.fromLTRB(
                                12,
                                0,
                                12,
                                8,
                              ),
                              title: const Text('高级设置'),
                              children: [
                                TextFormField(
                                  controller: _chunk,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: '每段建议字数',
                                  ),
                                  validator: (v) =>
                                      (int.tryParse(v ?? '') ?? 0) <= 0
                                      ? '请输入正整数'
                                      : null,
                                ),
                                TextFormField(
                                  controller: _prompt,
                                  minLines: 3,
                                  maxLines: 8,
                                  decoration: const InputDecoration(
                                    labelText: '语音提示词（可选）',
                                    helperText:
                                        '留空沿用默认；支持 {voice_frequency}、{max_chars_per_chunk}',
                                  ),
                                ),
                                Text('语音使用频率 $_frequency%（0 为不主动发语音）'),
                                MoeSlider(
                                  value: _frequency.toDouble(),
                                  min: 0,
                                  max: 100,
                                  divisions: 5,
                                  onChanged: (v) =>
                                      setState(() => _frequency = v.round()),
                                ),
                                SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('情感参考（支持此能力的模型）'),
                                  value: _useEmotion,
                                  onChanged: (v) =>
                                      setState(() => _useEmotion = v),
                                ),
                                if (_useEmotion)
                                  TextFormField(
                                    controller: _emotion,
                                    decoration: const InputDecoration(
                                      labelText: '情感描述',
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: MoeSettingsLayout.sectionGap),
                        MoeSettingsGroup(
                          title: '试听',
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                              child: TextFormField(
                                controller: _sample,
                                maxLines: 3,
                                decoration: const InputDecoration(
                                  labelText: '试听文本',
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                              child: OutlinedButton(
                                onPressed: () {
                                  if (!_validate()) return;
                                  _work(() async {
                                    if (_sample.text.trim().isEmpty) {
                                      throw StateError('请填写试听文本');
                                    }
                                    final request = await ref
                                        .read(voicePresetApplicationProvider)
                                        .preview(_draft());
                                    if (request.error != null) {
                                      throw StateError(request.error!);
                                    }
                                    final result = await request.service!
                                        .convert(_sample.text.trim());
                                    if (!result.success) {
                                      throw StateError(result.error ?? '试听失败');
                                    }
                                    if (mounted) {
                                      setState(() => _audio = result.audioUrl);
                                    }
                                  });
                                },
                                child: const Text('生成试听（调用供应商）'),
                              ),
                            ),
                            if (_audio != null)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  0,
                                  12,
                                  10,
                                ),
                                child: AudioPlayerWidget(
                                  block: AudioBlock(
                                    messageId: 'voice-preview-${_original.id}',
                                    url: _audio!,
                                    text: _sample.text,
                                  ),
                                  textColor: colors.text,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: MoeSettingsLayout.sectionGap),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: Text('修改自动保存，共享此预设的角色会使用更新后的设置。'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

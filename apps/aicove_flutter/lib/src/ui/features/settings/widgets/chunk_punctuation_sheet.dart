import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/message_formatter.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

/// Punctuation offered as one-tap toggles; anything else goes in the
/// free-text field below them.
const List<String> _kChinesePunctuations = [
  '。', '！', '？', '，', '、', '；', '：', '…', '～', //
];
const List<String> _kEnglishPunctuations = ['!', '?', ',', ';', '~'];
const List<String> kCommonChunkPunctuations = [
  ..._kChinesePunctuations,
  ..._kEnglishPunctuations,
];

const String _kPreviewSample =
    '嗯嗯，我到家啦！今天跑了一整天，好累……你呢？\n晚上一起吃饭吧～   想吃火锅 还是烤肉';

/// Space-run choices; 0 means spaces never split.
const List<int> _kSpaceRunChoices = [0, 1, 2, 3, 4];

/// Display name of [set], falling back to its position.
String chunkPunctuationSetName(MessageChunkPunctuationSet set, int index) {
  final name = set.name?.trim() ?? '';
  if (name.isNotEmpty) return name;
  return '未命名${(index < 0 ? 0 : index) + 1}';
}

/// 分段标点：选方案、点选标点、实时预览。所有聊天共用一套设置。
void showChunkPunctuationSheet(BuildContext context) {
  showMoeBottomSheet<void>(
    context: context,
    title: '分段标点',
    showCloseButton: true,
    builder: (_) => const ChunkPunctuationEditor(),
  );
}

class ChunkPunctuationEditor extends ConsumerStatefulWidget {
  const ChunkPunctuationEditor({super.key});

  @override
  ConsumerState<ChunkPunctuationEditor> createState() =>
      _ChunkPunctuationEditorState();
}

class _ChunkPunctuationEditorState extends ConsumerState<ChunkPunctuationEditor>
    with MoeAutoSaveState<ChunkPunctuationEditor> {
  final _custom = TextEditingController();
  final _customFocus = FocusNode();
  String? _boundSetId;

  MessageFormatConfig get _config =>
      ref.read(appSettingsProvider).requireValue.messageFormatConfig;

  AppSettingsNotifier get _notifier => ref.read(appSettingsProvider.notifier);

  static MessageChunkPunctuationSet? _currentOf(MessageFormatConfig? config) =>
      config?.activeChunkPunctuationSet;

  @override
  void initState() {
    super.initState();
    final active = _currentOf(
      ref.read(appSettingsProvider).valueOrNull?.messageFormatConfig,
    );
    if (active != null) _bind(active);
    ref.listenManual(appSettingsProvider, (_, _) => _follow());
  }

  void _follow() {
    final active = _currentOf(
      ref.read(appSettingsProvider).valueOrNull?.messageFormatConfig,
    );
    if (active == null) return;
    // Follow switches and outside edits unless the user is typing here.
    final outsideEdit =
        !autoSave.pending &&
        !_customFocus.hasFocus &&
        MessageFormatConfig.parsePunctuations(_custom.text).join(' ') !=
            _customTokens(active.punctuations).join(' ');
    if (active.id != _boundSetId || outsideEdit) _bind(active);
  }

  @override
  void dispose() {
    _custom.dispose();
    _customFocus.dispose();
    super.dispose();
  }

  static List<String> _customTokens(List<String> tokens) => [
    for (final t in tokens)
      if (!kCommonChunkPunctuations.contains(t)) t,
  ];

  /// Points the free-text field at [set] without counting it as an edit.
  void _bind(MessageChunkPunctuationSet set) {
    _boundSetId = set.id;
    _custom.text = _customTokens(set.punctuations).join(' ');
    autoSave.configure(
      save: _saveCustom,
      snapshot: () => _custom.text,
      fields: [_custom],
    );
  }

  Future<void> _saveCustom() async {
    final config = _config;
    final set = _currentOf(config);
    if (set == null || set.id != _boundSetId) return;
    final common = [
      for (final t in set.punctuations)
        if (kCommonChunkPunctuations.contains(t)) t,
    ];
    final typed = MessageFormatConfig.parsePunctuations(_custom.text);
    final next = config.withSetPunctuations(set.id, [
      ...common,
      for (final t in typed)
        if (!common.contains(t)) t,
    ]);
    if (next != null) await _notifier.updateMessageFormatConfig(next);
  }

  Future<void> _toggle(MessageChunkPunctuationSet set, String token) async {
    await autoSave.flush();
    final current = _currentOf(_config) ?? set;
    final tokens = [...current.punctuations];
    tokens.contains(token) ? tokens.remove(token) : tokens.add(token);
    final next = _config.withSetPunctuations(current.id, tokens);
    if (next != null) await _notifier.updateMessageFormatConfig(next);
  }

  /// Changes how line breaks and runs of spaces split under [set].
  Future<void> _setWhitespace(
    MessageChunkPunctuationSet set, {
    bool? splitOnNewline,
    int? spaceRun,
  }) async {
    final config = _config;
    final sets = [...config.chunkPunctuationSets];
    final i = sets.indexWhere((s) => s.id == set.id);
    if (i < 0) return;
    sets[i] = sets[i].copyWith(
      splitOnNewline: splitOnNewline,
      spaceRun: spaceRun,
    );
    await _notifier.updateMessageFormatConfig(
      config.copyWith(chunkPunctuationSets: sets),
    );
  }

  Future<void> _select(String setId) async {
    await autoSave.flush();
    final next = _config.withActiveSet(setId);
    if (next != null) await _notifier.updateMessageFormatConfig(next);
  }

  Future<void> _create(MessageChunkPunctuationSet source, int index) async {
    await autoSave.flush();
    if (!mounted) return;
    final controller = TextEditingController();
    final sourceName = chunkPunctuationSetName(source, index);
    final confirmed = await showMeoTalkDialog(
      context: context,
      title: '新建方案',
      cancelText: '取消',
      confirmText: '新建',
      content: MoeTextField(
        controller: controller,
        hint: '方案名称',
        helperText: '先复制「$sourceName」的设置，之后随意改',
        autofocus: true,
      ),
    );
    final name = controller.text.trim();
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (confirmed != true || !mounted) return;
    final config = _config;
    final copy = MessageChunkPunctuationSet(
      id: 'set_${DateTime.now().microsecondsSinceEpoch}',
      name: name.isEmpty ? null : name,
      punctuations: [...source.punctuations],
      splitOnNewline: source.splitOnNewline,
      spaceRun: source.spaceRun,
    );
    await _notifier.updateMessageFormatConfig(
      config.copyWith(
        chunkPunctuationSets: [...config.chunkPunctuationSets, copy],
        activeChunkPunctuationSetId: copy.id,
      ),
    );
  }

  Future<void> _rename(MessageChunkPunctuationSet target) async {
    await showMoeAutoSaveTextEditor(
      context: context,
      title: '重命名方案',
      initialValue: target.name ?? '',
      onSave: (text) async {
        final config = _config;
        final sets = [...config.chunkPunctuationSets];
        final i = sets.indexWhere((s) => s.id == target.id);
        if (i < 0) throw const FormatException('这个方案已经删除');
        sets[i] = sets[i].copyWith(
          name: text.trim().isEmpty ? null : text.trim(),
        );
        await _notifier.updateMessageFormatConfig(
          config.copyWith(chunkPunctuationSets: sets),
        );
      },
    );
  }

  Future<void> _delete(MessageChunkPunctuationSet target, String name) async {
    final confirmed = await showMeoTalkConfirm(
      context: context,
      title: '删除方案',
      message: '删除「$name」？删除后无法恢复。',
      confirmText: '删除',
      cancelText: '取消',
      isDanger: true,
    );
    if (confirmed != true || !mounted) return;
    final config = _config;
    final sets = config.chunkPunctuationSets
        .where((s) => s.id != target.id)
        .toList();
    if (sets.isEmpty) return;
    await _notifier.updateMessageFormatConfig(
      config.copyWith(
        chunkPunctuationSets: sets,
        activeChunkPunctuationSetId:
            config.activeChunkPunctuationSetId == target.id
            ? sets.first.id
            : config.activeChunkPunctuationSetId,
      ),
    );
  }

  void _showSetActions(
    MessageChunkPunctuationSet set,
    String name,
    bool canDelete,
  ) {
    showMoeActionSheet(
      context: context,
      title: name,
      actions: [
        MoeSheetAction(
          label: '重命名',
          icon: Icons.edit_outlined,
          onTap: () => _rename(set),
        ),
        MoeSheetAction(
          label: '删除',
          icon: Icons.delete_outline,
          isDestructive: true,
          isDisabled: !canDelete,
          subtitle: canDelete ? null : '至少保留一个方案',
          onTap: () => _delete(set, name),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final colors = context.moeColors;
    if (settings == null) {
      return const SizedBox(
        height: 200,
        child: Center(child: MoeLoadingIndicator()),
      );
    }
    final config = settings.messageFormatConfig;
    final sets = config.chunkPunctuationSets;
    final active = config.activeChunkPunctuationSet ?? sets.first;
    final activeIndex = sets.indexWhere((s) => s.id == active.id);
    final activeName = chunkPunctuationSetName(active, activeIndex);
    final preview = MessageFormatter.formatAndChunkText(
      _kPreviewSample,
      config.copyWith(enableChunking: true),
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label(colors, '方案'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < sets.length; i++)
                MoeChoiceChip(
                  label: chunkPunctuationSetName(sets[i], i),
                  selected: sets[i].id == active.id,
                  onTap: () => _select(sets[i].id),
                ),
              MoeChoiceChip(
                label: '新建',
                icon: Icons.add,
                selected: false,
                muted: true,
                onTap: () => _create(active, activeIndex),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(child: _label(colors, '「$activeName」在哪里分段')),
              MoeIconButton(
                icon: Icons.more_horiz,
                size: 20,
                padding: const EdgeInsets.all(6),
                minTouchTarget: 32,
                color: colors.muted,
                tooltip: '方案操作',
                onTap: () =>
                    _showSetActions(active, activeName, sets.length > 1),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final (caption, tokens) in [
            ('中文', _kChinesePunctuations),
            ('英文', _kEnglishPunctuations),
          ]) ...[
            Text(caption, style: TextStyle(fontSize: 12, color: colors.muted)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final token in tokens)
                  SizedBox(
                    width: 44,
                    child: MoeChoiceChip(
                      label: token,
                      expand: true,
                      selected: active.punctuations.contains(token),
                      onTap: () => _toggle(active, token),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          MoeTextField(
            controller: _custom,
            focusNode: _customFocus,
            label: '其他标点',
            hint: '例如 ♪ ……',
            helperText: '用空格隔开',
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text(
                  '换行处分段',
                  style: TextStyle(fontSize: 14, color: colors.text),
                ),
              ),
              MoeSwitch(
                value: active.splitOnNewline,
                semanticLabel: '换行处分段',
                onChanged: (value) =>
                    _setWhitespace(active, splitOnNewline: value),
              ),
            ],
          ),
          Text(
            '打开后回复每换一行就拆成新气泡，关闭则换行留在同一条里',
            style: TextStyle(fontSize: 12, color: colors.muted),
          ),
          const SizedBox(height: 16),
          Text('连续空格分段', style: TextStyle(fontSize: 14, color: colors.text)),
          const SizedBox(height: 8),
          MoeSegmentedControl<int>(
            value: _kSpaceRunChoices.contains(active.spaceRun)
                ? active.spaceRun
                : kDefaultChunkSpaceRun,
            segments: [
              for (final run in _kSpaceRunChoices)
                MoeSegment(value: run, label: run == 0 ? '不分' : '$run 个'),
            ],
            onChanged: (run) => _setWhitespace(active, spaceRun: run),
          ),
          const SizedBox(height: 4),
          Text(switch (active.spaceRun) {
            0 => '空格不会拆开气泡',
            1 => '遇到空格就拆开，英文句子也会按单词拆散',
            final run => '连续 $run 个及以上空格时拆开',
          }, style: TextStyle(fontSize: 12, color: colors.muted)),
          const SizedBox(height: 20),
          _label(colors, '效果预览'),
          const SizedBox(height: 4),
          Text(
            preview.length <= 1
                ? '按现在的设置，这段回复不会拆开'
                : '回复会按下面这样拆成 ${preview.length} 条气泡',
            style: TextStyle(fontSize: 12, color: colors.muted),
          ),
          const SizedBox(height: 10),
          for (final chunk in preview)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: MoeG2Decoration(
                  radius: 14,
                  color: colors.surfaceAlt,
                  border: Border.all(color: colors.borderLight),
                ),
                child: Text(
                  chunk,
                  style: TextStyle(fontSize: 14, color: colors.text),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _label(MoeColors colors, String text) => Text(
    text,
    style: TextStyle(
      fontSize: 13,
      fontWeight: MoeFontWeights.emphasis,
      color: colors.textSecondary,
    ),
  );
}

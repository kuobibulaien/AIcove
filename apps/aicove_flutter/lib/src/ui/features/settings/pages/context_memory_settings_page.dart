/// ContextMemorySettingsPage - 上下文与记忆设置页面
///
/// 集中配置上下文窗口、压缩模型与记忆模型，并说明短期／长期记忆如何联动（ADR0038）。
///
/// 更新记录：
/// - 2026-09-19: 以「自动压缩」页创建
/// - 2026-09-23: 改为「上下文与记忆」，压缩模型与记忆模型改存全局设置
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/settings/app_settings.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

class ContextMemorySettingsPage extends ConsumerStatefulWidget {
  const ContextMemorySettingsPage({super.key});

  @override
  ConsumerState<ContextMemorySettingsPage> createState() =>
      _ContextMemorySettingsPageState();
}

class _ContextMemorySettingsPageState
    extends ConsumerState<ContextMemorySettingsPage>
    with MoeAutoSaveState<ContextMemorySettingsPage> {
  String _compactionModel = '';
  String _memoryModel = '';
  late TextEditingController _contextWindowCtrl;
  bool _initialized = false;

  @override
  void dispose() {
    if (_initialized) _contextWindowCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final colors = context.moeColors;
    return autoSavePage(
      MoePageScaffold(
        appBar: const MoeAppBar(title: '上下文与记忆', showBackButton: true),
        backgroundColor: colors.surface,
        body: settingsAsync.when(
          loading: () =>
              const Center(child: MoeLoadingIndicator(message: '加载中...')),
          error: (e, _) => Center(child: Text('加载失败: $e')),
          data: (settings) => _buildBody(settings, colors),
        ),
      ),
    );
  }

  Widget _buildBody(AppSettings settings, MoeColors colors) {
    _ensureInitialized(settings);
    final choices = _collectChatModels(settings);
    return MoeSettingsContent(
      child: ListView(
        padding: MoeSettingsLayout.verticalListPadding,
        children: [
          MoeSettingsGroup(
            padding: MoeSettingsLayout.contentPadding,
            children: [
              Text(
                '短期记忆：聊天快装不下时，较早的对话会被整理成摘要（自动压缩）；'
                '也可以在聊天页手动「压缩并开启新话题」。原始聊天记录始终完整保留。\n'
                '长期记忆：每次压缩后，记忆模型会在后台把刚整理过的对话提炼进该角色的记忆，'
                '聊天时自动带上相关内容。聊天模型本身不会调用记忆工具。',
                style: TextStyle(color: colors.text, fontSize: 13, height: 1.5),
              ),
            ],
          ),
          const SizedBox(height: MoeSettingsLayout.sectionGap),
          MoeSettingsGroup(
            title: '模型',
            children: [
              MoeSettingsRow(
                label: '压缩模型',
                subtitle: _subtitle(
                  settings,
                  _compactionModel,
                  fallback: '跟随默认聊天模型',
                ),
                onTap: () => _pick(
                  title: '选择压缩模型',
                  fallbackLabel: '跟随默认聊天模型',
                  current: _compactionModel,
                  choices: choices,
                  onSelected: (ref) => setState(() => _compactionModel = ref),
                ),
              ),
              MoeSettingsRow(
                label: '记忆模型',
                subtitle: _subtitle(
                  settings,
                  _memoryModel,
                  fallback: '跟随压缩模型',
                ),
                showDivider: false,
                onTap: () => _pick(
                  title: '选择记忆模型',
                  fallbackLabel: '跟随压缩模型',
                  current: _memoryModel,
                  choices: choices,
                  onSelected: (ref) => setState(() => _memoryModel = ref),
                ),
              ),
            ],
          ),
          const SizedBox(height: MoeSettingsLayout.sectionGap),
          MoeSettingsGroup(
            title: '上下文窗口',
            children: [
              Padding(
                padding: MoeSettingsLayout.contentPadding,
                child: MoeTextField(
                  controller: _contextWindowCtrl,
                  label: '窗口大小（k tokens）',
                  hint: '272',
                  helperText: '默认 272k；与默认模型设置中的上下文窗口共用',
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  textInputAction: TextInputAction.done,
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: MoeSettingsLayout.sectionGap),
          const MoeSettingsGroup(
            title: '规则',
            padding: MoeSettingsLayout.contentPadding,
            children: [
              Text(
                '实际窗口受当前聊天模型及预设容量限制。达到窗口约 80% 或扣除输出预留后的上限时自动压缩，'
                '近期原文约保留窗口的 16%。压缩失败不会删除原始聊天，可更换压缩模型后重试。\n'
                '长期记忆分「常驻」和「档案」：常驻约 2000 tokens，每轮都带；档案按当前话题检索后带上最相关的几条。'
                '只有在角色的插件列表里打开「记忆库」的角色才会整理和使用长期记忆，'
                '可在角色资料的记忆页查看、编辑或从聊天记录重建。',
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _ensureInitialized(AppSettings settings) {
    if (_initialized) return;
    _compactionModel = settings.compactionModel;
    _memoryModel = settings.memoryModel;
    _contextWindowCtrl = TextEditingController(
      text: (settings.contextWindowTokens / 1000).toStringAsFixed(
        settings.contextWindowTokens % 1000 == 0 ? 0 : 3,
      ),
    );
    _initialized = true;
    autoSave.configure(
      save: _save,
      snapshot: () => moeAutoSaveSignature([
        _contextWindowCtrl.text,
        _compactionModel,
        _memoryModel,
      ]),
      fields: [_contextWindowCtrl],
    );
  }

  Future<void> _save() async {
    final text = _contextWindowCtrl.text.trim();
    final parsed = double.tryParse(text);
    if (!RegExp(r'^\d+(?:\.\d{1,3})?$').hasMatch(text) ||
        parsed == null ||
        !parsed.isFinite ||
        parsed < 0.001 ||
        parsed > 2147483) {
      throw const FormatException('上下文窗口请输入大于 0 的数字（k tokens）');
    }
    final notifier = ref.read(appSettingsProvider.notifier);
    await notifier.setContextWindowTokens((parsed * 1000).round());
    await notifier.setCompactionModel(_compactionModel);
    await notifier.setMemoryModel(_memoryModel);
  }

  String _subtitle(
    AppSettings settings,
    String modelRef, {
    required String fallback,
  }) => modelRef.isEmpty
      ? fallback
      : '${settings.getModelDisplayName(modelRef)}（$modelRef）';

  List<_ModelChoice> _collectChatModels(AppSettings settings) {
    final result = <_ModelChoice>[];
    for (final provider in settings.providers) {
      if (!provider.enabled) continue;
      final visible = settings.getProviderVisibleModelsByType(
        provider.id,
        type: ModelType.chat,
      );
      final candidates = visible.isNotEmpty
          ? visible
          : settings.getProviderModelsByType(provider.id, type: ModelType.chat);
      for (final modelName in candidates) {
        result.add(
          _ModelChoice(
            modelRef: settings.buildModelRef(provider.id, modelName),
            providerName: provider.displayName ?? provider.id,
            modelName: modelName,
          ),
        );
      }
    }
    return result;
  }

  void _pick({
    required String title,
    required String fallbackLabel,
    required String current,
    required List<_ModelChoice> choices,
    required void Function(String modelRef) onSelected,
  }) {
    IconData mark(bool selected) =>
        selected ? Icons.check_circle : Icons.circle_outlined;
    showMoeActionSheet(
      context: context,
      title: title,
      actions: [
        MoeSheetAction(
          icon: mark(current.isEmpty),
          label: fallbackLabel,
          onTap: () => onSelected(''),
        ),
        // 渠道被禁用或删除时，当前配置仍要可见并可清除。
        if (current.isNotEmpty && !choices.any((c) => c.modelRef == current))
          MoeSheetAction(
            icon: mark(true),
            label: current,
            subtitle: '当前不可选',
            onTap: () => onSelected(current),
          ),
        for (final choice in choices)
          MoeSheetAction(
            icon: mark(choice.modelRef == current),
            label: choice.modelName,
            subtitle: choice.providerName,
            onTap: () => onSelected(choice.modelRef),
          ),
      ],
      showCancelButton: true,
    );
  }
}

class _ModelChoice {
  const _ModelChoice({
    required this.modelRef,
    required this.providerName,
    required this.modelName,
  });
  final String modelRef, providerName, modelName;
}

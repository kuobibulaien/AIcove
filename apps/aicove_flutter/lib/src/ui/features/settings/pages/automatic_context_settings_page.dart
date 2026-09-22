/// AutomaticContextSettingsPage - 自动压缩设置页面
///
/// 配置自动压缩共用的总结模型与上下文窗口，并说明触发口径。
///
/// 更新记录：
/// - 2026-09-19: 创建
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/plugins/memory/memory_config.dart';
import '../../../../features/plugins/plugin_providers.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

/// 自动压缩设置页面
class AutomaticContextSettingsPage extends ConsumerStatefulWidget {
  const AutomaticContextSettingsPage({super.key});

  @override
  ConsumerState<AutomaticContextSettingsPage> createState() =>
      _AutomaticContextSettingsPageState();
}

class _AutomaticContextSettingsPageState
    extends ConsumerState<AutomaticContextSettingsPage>
    with MoeAutoSaveState<AutomaticContextSettingsPage> {
  /// 本地状态：总结模型（与手动压缩共用同一份配置）
  String? _providerId;
  String? _modelName;

  /// 本地状态：上下文窗口
  late TextEditingController _contextWindowCtrl;
  bool _initialized = false;

  @override
  void dispose() {
    if (_initialized) {
      _contextWindowCtrl.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    ref.listen(memoryPluginConfigProvider, (previous, next) {
      if (!_initialized || autoSave.pending || autoSave.saving) return;
      setState(() {
        _providerId = next.summarizeProviderId;
        _modelName = next.summarizeModelName;
        autoSave.configure(
          save: _save,
          snapshot: () => moeAutoSaveSignature([
            _contextWindowCtrl.text,
            _providerId,
            _modelName,
          ]),
          fields: [_contextWindowCtrl],
        );
      });
    });
    final config = ref.watch(memoryPluginConfigProvider);
    final colors = context.moeColors;

    return autoSavePage(
      MoePageScaffold(
        appBar: const MoeAppBar(title: '自动压缩', showBackButton: true),
        backgroundColor: colors.surface,
        body: settingsAsync.when(
          loading: () =>
              const Center(child: MoeLoadingIndicator(message: '加载中...')),
          error: (e, _) => Center(child: Text('加载失败: $e')),
          data: (settings) => _buildBody(settings, config, colors),
        ),
      ),
    );
  }

  Widget _buildBody(
    AppSettings settings,
    MemoryConfig config,
    MoeColors colors,
  ) {
    _ensureLocalStateInitialized(settings, config);
    final choices = _collectChatModels(settings);
    final selected = _resolveSelectedChoice(
      choices,
      providerId: _providerId,
      modelName: _modelName,
    );
    final effectiveModelRef = selected == null
        ? _defaultChatModelRef(settings)
        : settings.buildModelRef(selected.providerId, selected.modelName);

    return MoeSettingsContent(
      child: ListView(
        padding: MoeSettingsLayout.verticalListPadding,
        children: [
          MoeSettingsGroup(
            padding: MoeSettingsLayout.contentPadding,
            children: [
              Text(
                '接近窗口容量时，自动压缩把较早的对话整理成摘要后继续当前对话，原始聊天记录完整保留。'
                '这里的总结模型与手动「压缩并开启新话题」共用同一份配置；它只负责整理历史，'
                '日常回复仍由默认聊天模型完成。',
                style: TextStyle(color: colors.text, fontSize: 13, height: 1.5),
              ),
            ],
          ),
          const SizedBox(height: MoeSettingsLayout.sectionGap),
          MoeSettingsGroup(
            title: '总结模型',
            children: [
              MoeSettingsRow(
                label: '点击选择模型',
                subtitle: selected == null
                    ? '跟随默认聊天模型：${_modelLabel(settings, effectiveModelRef)}'
                    : '${selected.providerName} / ${settings.getModelDisplayName(selected.modelName)}',
                showDivider: false,
                onTap: () =>
                    _showModelPicker(choices: choices, currentChoice: selected),
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
            title: '触发规则',
            padding: MoeSettingsLayout.contentPadding,
            children: [
              Text(
                '实际窗口受当前聊天模型及预设容量限制，并非总结模型容量。'
                '达到窗口约 80% 或扣除输出预留后的上限时触发压缩；'
                '近期原文预算约为窗口的 16%，必要时进一步整理。'
                '总结模型按自身窗口分批处理。压缩失败不会删除原始聊天，'
                '可更换总结模型后重试；切换聊天模型不会自动切换总结模型。',
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _ensureLocalStateInitialized(AppSettings settings, MemoryConfig config) {
    if (_initialized) return;
    _providerId = config.summarizeProviderId;
    _modelName = config.summarizeModelName;
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
        _providerId,
        _modelName,
      ]),
      fields: [_contextWindowCtrl],
    );
  }

  Future<void> _save() async {
    final text = _contextWindowCtrl.text.trim();
    final parsed = double.tryParse(text);
    final providerId = _providerId;
    final modelName = _modelName;
    if (!RegExp(r'^\d+(?:\.\d{1,3})?$').hasMatch(text) ||
        parsed == null ||
        !parsed.isFinite ||
        parsed < 0.001 ||
        parsed > 2147483) {
      throw const FormatException('上下文窗口请输入大于 0 的数字（k tokens）');
    }
    await ref
        .read(appSettingsProvider.notifier)
        .setContextWindowTokens((parsed * 1000).round());
    await ref
        .read(memoryPluginConfigProvider.notifier)
        .setSummarizeModel(providerId, modelName);
  }

  String _defaultChatModelRef(AppSettings settings) =>
      settings.defaultChatModels.isNotEmpty
      ? settings.defaultChatModels.first
      : settings.defaultModelName;

  String _modelLabel(AppSettings settings, String modelRef) => modelRef.isEmpty
      ? '跟随默认聊天模型'
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
            providerId: provider.id,
            providerName: provider.displayName ?? provider.id,
            modelName: modelName,
          ),
        );
      }
    }
    return result;
  }

  _ModelChoice? _resolveSelectedChoice(
    List<_ModelChoice> choices, {
    required String? providerId,
    required String? modelName,
  }) {
    final pid = providerId?.trim() ?? '';
    final name = modelName?.trim() ?? '';
    if (name.isEmpty) return null;
    for (final choice in choices) {
      if (choice.modelName == name && choice.providerId == pid) {
        return choice;
      }
    }
    // 渠道被禁用或删除时当前配置仍要可见并可清除。
    return _ModelChoice(
      providerId: pid,
      providerName: pid.isEmpty ? '旧版模型配置' : '$pid（当前不可选）',
      modelName: name,
    );
  }

  void _showModelPicker({
    required List<_ModelChoice> choices,
    required _ModelChoice? currentChoice,
  }) {
    final actions = <MoeSheetAction>[
      MoeSheetAction(
        icon: currentChoice == null
            ? Icons.check_circle
            : Icons.circle_outlined,
        label: '跟随默认聊天模型',
        subtitle: '清空总结模型配置',
        onTap: () => _selectModel(null, null),
      ),
      for (final choice in choices)
        MoeSheetAction(
          icon:
              currentChoice != null &&
                  currentChoice.providerId == choice.providerId &&
                  currentChoice.modelName == choice.modelName
              ? Icons.check_circle
              : Icons.circle_outlined,
          label: choice.modelName,
          subtitle: choice.providerName,
          onTap: () => _selectModel(choice.providerId, choice.modelName),
        ),
    ];
    showMoeActionSheet(
      context: context,
      title: '选择总结模型',
      description: '与手动「压缩并开启新话题」共用',
      actions: actions,
      showCancelButton: true,
    );
  }

  void _selectModel(String? providerId, String? modelName) {
    setState(() {
      _providerId = providerId;
      _modelName = modelName;
    });
  }
}

class _ModelChoice {
  final String providerId;
  final String providerName;
  final String modelName;

  const _ModelChoice({
    required this.providerId,
    required this.providerName,
    required this.modelName,
  });
}

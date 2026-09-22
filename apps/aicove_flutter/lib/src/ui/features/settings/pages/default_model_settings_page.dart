/// DefaultModelSettingsPage - 默认模型设置页面
///
/// 设置默认聊天模型（多选，有序，支持轮询）。
///
/// 更新记录：
/// - 2026-02-20: 创建
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/settings/app_settings.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import 'automatic_context_settings_page.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';

/// 默认模型设置页面
class DefaultModelSettingsPage extends ConsumerStatefulWidget {
  const DefaultModelSettingsPage({super.key});

  @override
  ConsumerState<DefaultModelSettingsPage> createState() =>
      _DefaultModelSettingsPageState();
}

class _DefaultModelSettingsPageState
    extends ConsumerState<DefaultModelSettingsPage>
    with MoeAutoSaveState<DefaultModelSettingsPage> {
  /// 本地状态：选中的聊天模型列表（有序）
  List<String>? _localChatModels;

  /// 本地状态：上下文窗口
  late TextEditingController _contextWindowCtrl;
  bool _contextWindowInitialized = false;

  @override
  void dispose() {
    if (_contextWindowInitialized) {
      _contextWindowCtrl.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final colors = context.moeColors;

    return autoSavePage(
      MoePageScaffold(
        appBar: const MoeAppBar(title: '默认模型设置', showBackButton: true),
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
    _ensureLocalStateInitialized(settings);
    final chatModels = _buildChatModels(settings);
    final selectedChatModels = _localChatModels ?? settings.defaultChatModels;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        // ============ 默认聊天模型 ============
        _buildSectionHeader(colors, '默认聊天模型', '可多选，失败后自动尝试下一个模型'),
        const SizedBox(height: 8),
        MoeSettingsGroup(
          margin: EdgeInsets.zero,
          padding: EdgeInsets.zero,
          children: [
            if (chatModels.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '暂无可用的聊天模型，请先添加供应商',
                  style: TextStyle(color: colors.muted, fontSize: 13),
                ),
              )
            else
              ...chatModels.map((entry) {
                final isSelected = selectedChatModels.contains(entry.modelRef);
                final order = selectedChatModels.indexOf(entry.modelRef);
                return MoeSettingsRow(
                  iconWidget: _buildOrderBadge(isSelected, order, colors),
                  iconContainerWidth: 28,
                  label: entry.displayName,
                  subtitle: entry.providerName,
                  trailingType: MoeSettingsRowTrailing.custom,
                  trailing: MoeCheckbox(
                    value: isSelected,
                    onChanged: (_) =>
                        _toggleChatModel(entry.modelRef, settings),
                    size: MoeCheckboxSize.md,
                  ),
                  onTap: () => _toggleChatModel(entry.modelRef, settings),
                  showDivider: entry != chatModels.last,
                );
              }),
          ],
        ),

        const SizedBox(height: 24),

        MoeSettingsGroup(
          margin: EdgeInsets.zero,
          children: [
            MoeSettingsRow(
              label: '自动压缩',
              subtitle: '总结模型、上下文窗口与触发规则',
              trailingType: MoeSettingsRowTrailing.chevron,
              onTap: () async {
                if (!await autoSave.flush() || !mounted) return;
                await Navigator.of(context).push(
                  ParallaxSlidePageRoute(
                    page: const AutomaticContextSettingsPage(),
                  ),
                );
                if (!mounted) return;
                final latest = ref.read(appSettingsProvider).valueOrNull;
                if (latest == null) return;
                _contextWindowCtrl.text = (latest.contextWindowTokens / 1000)
                    .toStringAsFixed(
                      latest.contextWindowTokens % 1000 == 0 ? 0 : 3,
                    );
                autoSave.configure(
                  save: _saveContextWindowTokens,
                  snapshot: () => _contextWindowCtrl.text,
                  fields: [_contextWindowCtrl],
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 24),
        // ============ 上下文窗口 ============
        _buildSectionHeader(colors, '上下文窗口', '接近窗口容量时自动压缩对话'),
        const SizedBox(height: 8),
        MoeSettingsGroup(
          margin: EdgeInsets.zero,
          padding: EdgeInsets.zero,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MoeTextField(
                    controller: _contextWindowCtrl,
                    label: '窗口大小（k tokens）',
                    hint: '272',
                    helperText: '默认 272k，约用到 80% 时自动压缩；原始聊天保留',
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.digitsOnly,
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  void _ensureLocalStateInitialized(AppSettings settings) {
    if (!_contextWindowInitialized) {
      _contextWindowCtrl = TextEditingController(
        text: (settings.contextWindowTokens / 1000).toStringAsFixed(
          settings.contextWindowTokens % 1000 == 0 ? 0 : 3,
        ),
      );
      _contextWindowInitialized = true;
      autoSave.configure(
        save: _saveContextWindowTokens,
        snapshot: () => _contextWindowCtrl.text,
        fields: [_contextWindowCtrl],
      );
    }
  }

  List<_ModelEntry> _buildChatModels(AppSettings settings) {
    final chatModels = <_ModelEntry>[];
    for (final provider in settings.providers) {
      if (!provider.enabled) continue;
      final providerName = provider.displayName ?? provider.id;
      for (final modelId in provider.visibleModels) {
        final modelRef = settings.buildModelRef(provider.id, modelId);
        if (settings.getModelType(modelRef) != ModelType.chat) {
          continue;
        }
        chatModels.add(
          _ModelEntry(
            modelRef: modelRef,
            modelId: modelId,
            providerId: provider.id,
            providerName: providerName,
            displayName: settings.getModelDisplayName(modelRef),
          ),
        );
      }
    }
    return chatModels;
  }

  Widget _buildSectionHeader(
    MoeColors colors,
    String title,
    String description,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 14,
            fontWeight: MoeFontWeights.emphasis,
            color: colors.text,
          ),
        ),
        const SizedBox(height: 2),
        Text(description, style: TextStyle(fontSize: 12, color: colors.muted)),
      ],
    );
  }

  Widget _buildOrderBadge(bool isSelected, int order, MoeColors colors) {
    if (!isSelected) {
      return SizedBox(
        width: 20,
        height: 20,
        child: Center(
          child: MoeG2ClipRRect(
            radius: 10,
            child: Container(
              width: 20,
              height: 20,
              decoration: MoeG2Decoration(
                radius: 10,
                color: colors.muted.withValues(alpha: 0.15),
              ),
              child: Center(
                child: Text(
                  '-',
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.muted,
                    fontWeight: MoeFontWeights.emphasis,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return SizedBox(
      width: 20,
      height: 20,
      child: Center(
        child: MoeG2ClipRRect(
          radius: 10,
          child: Container(
            width: 20,
            height: 20,
            decoration: MoeG2Decoration(
              radius: 10,
              color: colors.primary.withValues(alpha: 0.15),
            ),
            child: Center(
              child: Text(
                '${order + 1}',
                style: TextStyle(
                  fontSize: 11,
                  color: colors.primary,
                  fontWeight: MoeFontWeights.emphasis,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _toggleChatModel(String modelRef, AppSettings settings) {
    setState(() {
      final current = List<String>.from(
        _localChatModels ?? settings.defaultChatModels,
      );
      if (current.contains(modelRef)) {
        current.remove(modelRef);
      } else {
        current.add(modelRef);
      }
      _localChatModels = current;
    });

    // 保存
    ref
        .read(appSettingsProvider.notifier)
        .setDefaultChatModels(_localChatModels!);
  }

  Future<void> _saveContextWindowTokens() async {
    final parsed = int.tryParse(_contextWindowCtrl.text.trim());
    if (parsed == null || parsed <= 0) {
      throw const FormatException('上下文窗口请输入大于 0 的整数');
    }
    await ref
        .read(appSettingsProvider.notifier)
        .setContextWindowTokens(parsed * 1000);
  }
}

/// 模型条目
class _ModelEntry {
  final String modelRef;
  final String modelId;
  final String providerId;
  final String providerName;
  final String displayName;

  const _ModelEntry({
    required this.modelRef,
    required this.modelId,
    required this.providerId,
    required this.providerName,
    required this.displayName,
  });
}

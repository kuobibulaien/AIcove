/// ProviderSectionCard - 渠道卡片组件
/// 
/// 从 model_list_page.dart 提取，显示单个服务提供商的信息。
/// 
/// 设计特点：
/// - 显示渠道名称、域名、API Key
/// - 显示能力标签
/// - 点击触发底部操作菜单
/// - 展示已显示和隐藏的模型列表
/// 
/// 更新记录：
/// - 2025-12-31: 从 model_list_page.dart 提取
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/settings/app_settings.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/index.dart';
import 'model_row_tile.dart';
import 'provider_dialogs.dart';

/// 渠道卡片组件（用于渠道列表展示）
class ProviderSectionCard extends ConsumerWidget {
  final ProviderAuth provider;
  final Map<String, String> displayNames;

  const ProviderSectionCard({
    super.key,
    required this.provider,
    required this.displayNames,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = _sortedModels(provider.visibleModels, displayNames);
    final hidden = _sortedModels(provider.hiddenModels, displayNames);
    final title = providerTitle(provider);
    final notifier = ref.read(appSettingsProvider.notifier);
    final colors = context.moeColors;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      color: colors.surfaceAlt,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _showProviderActions(context, ref),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题和状态区域
              _buildHeader(context, colors, title),
              const SizedBox(height: 16),

              // 已显示模型
              Text('已显示模型', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              if (visible.isEmpty)
                Text('暂无可见模型', style: TextStyle(color: colors.muted, fontSize: 12))
              else
                Column(
                  children: visible
                      .map((model) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: ModelRowTile(
                              providerId: provider.id,
                              model: model,
                              displayName: displayNames[model],
                              canHide: visible.length > 1,
                              providerEnabled: provider.enabled,
                            ),
                          ))
                      .toList(),
                ),

              // 隐藏模型
              if (hidden.isNotEmpty) ...[
                const SizedBox(height: 12),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text('隐藏模型（${hidden.length}）', style: const TextStyle(fontSize: 14)),
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: hidden
                          .map(
                            (model) => ActionChip(
                              avatar: const Icon(Icons.visibility_outlined, size: 16),
                              label: Text(
                                displayNames[model]?.isNotEmpty == true
                                    ? '${displayNames[model]} ($model)'
                                    : model,
                              ),
                              onPressed: provider.enabled
                                  ? () {
                                      notifier.setModelVisibility(
                                        providerId: provider.id,
                                        modelId: model,
                                        visible: true,
                                      );
                                    }
                                  : null,
                            ),
                          )
                          .toList(),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 构建头部区域
  Widget _buildHeader(BuildContext context, MoeColors colors, String title) {
    return Row(
      children: [
        Icon(Icons.hub, color: colors.primary, size: 24),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                _extractDomain(provider.apiBaseUrl),
                style: TextStyle(color: colors.muted, fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
              if (provider.apiKeys.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    'Key: ${provider.apiKeys.first}',
                    style: TextStyle(
                      color: colors.muted,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              const SizedBox(height: 6),
              // 能力标签
              _buildCapabilityTags(colors),
              // 停用标记
              if (!provider.enabled)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Chip(
                    visualDensity: VisualDensity.compact,
                    backgroundColor: colors.dialogWarning,
                    label: const Text('已停用'),
                    labelStyle: TextStyle(color: colors.text, fontSize: 11),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                  ),
                ),
            ],
          ),
        ),
        // 操作提示图标
        Icon(Icons.more_vert, color: colors.muted, size: 20),
      ],
    );
  }

  /// 构建能力标签
  Widget _buildCapabilityTags(MoeColors colors) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: provider.capabilities.map((cap) {
        final capInfo = getCapabilityInfo(cap);
        return Tooltip(
          message: capInfo.label,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: colors.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: colors.primary.withValues(alpha: 0.3),
                width: 0.5,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(capInfo.icon, size: 12, color: colors.primary),
                const SizedBox(width: 4),
                Text(
                  capInfo.shortLabel,
                  style: TextStyle(
                    color: colors.primary,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  /// 显示渠道操作菜单
  void _showProviderActions(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(appSettingsProvider.notifier);
    final title = providerTitle(provider);

    showMoeActionSheet(
      context: context,
      title: title,
      description: _extractDomain(provider.apiBaseUrl),
      actions: [
        MoeSheetAction(
          icon: Icons.edit_outlined,
          label: '编辑渠道',
          onTap: () => showEditProviderDialog(context, ref, provider),
        ),
        MoeSheetAction(
          icon: Icons.wifi_tethering,
          label: '测试连接',
          onTap: () => testConnection(context, ref, provider),
        ),
        MoeSheetAction(
          icon: provider.enabled ? Icons.pause_circle_outline : Icons.play_circle_outline,
          label: provider.enabled ? '停用渠道' : '启用渠道',
          subtitle: provider.enabled ? '停用后模型不会出现在切换列表' : '启用后模型将重新可用',
          onTap: () async {
            await notifier.setProviderEnabled(provider.id, !provider.enabled);
          },
        ),
        MoeSheetAction(
          icon: Icons.delete_outline,
          label: '删除渠道',
          isDestructive: true,
          onTap: () async {
            final confirm = await showMeoTalkConfirm(
              context: context,
              title: '删除渠道',
              message: '确认删除渠道「$title」及其模型配置？该操作不可恢复。',
            );
            if (confirm == true) {
              await notifier.deleteProvider(provider.id);
            }
          },
        ),
      ],
    );
  }
}

// === 辅助函数 ===

/// 获取渠道显示名称
String providerTitle(ProviderAuth provider) =>
    provider.displayName?.isNotEmpty == true ? provider.displayName! : provider.id;

/// 对模型列表排序
List<String> _sortedModels(List<String> models, Map<String, String> displayNames) {
  final unique = <String>[];
  final seen = <String>{};
  for (final model in models) {
    if (seen.add(model)) {
      unique.add(model);
    }
  }
  unique.sort((a, b) {
    final labelA = (displayNames[a] ?? a).toLowerCase();
    final labelB = (displayNames[b] ?? b).toLowerCase();
    return labelA.compareTo(labelB);
  });
  return unique;
}

/// 从 URL 提取域名
String _extractDomain(String url) {
  try {
    final uri = Uri.parse(url);
    return uri.host.isNotEmpty ? uri.host : url;
  } catch (_) {
    return url;
  }
}

/// 能力信息
class CapabilityInfo {
  final String label;
  final String shortLabel;
  final IconData icon;
  const CapabilityInfo(this.label, this.shortLabel, this.icon);
}

/// 获取能力信息
CapabilityInfo getCapabilityInfo(String capability) {
  switch (capability) {
    case 'chat':
      return const CapabilityInfo('聊天对话', '聊天', Icons.chat_bubble_outline);
    case 'embedding':
      return const CapabilityInfo('向量嵌入', '嵌入', Icons.scatter_plot);
    case 'tts':
      return const CapabilityInfo('语音生成', '语音', Icons.record_voice_over);
    case 'image':
      return const CapabilityInfo('图片生成', '图片', Icons.image_outlined);
    default:
      return const CapabilityInfo('未知', '?', Icons.help_outline);
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../../../features/backup/models/export_format.dart';
import '../../../../features/backup/backup_providers.dart';
import '../../../shared/animations/parallax_slide_page_route.dart';
import '../../../shared/effects/smooth_clip.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import 'export_character_page.dart';

/// 导出范围选择页面
class ExportScopePage extends ConsumerWidget {
  const ExportScopePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options = ref.watch(exportOptionsProvider);
    final theme = Theme.of(context);

    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      appBar: MoeAppBar(title: '选择导出内容', showBackButton: true),
      body: Column(
        children: [
          Expanded(
            child: Builder(
              builder: (context) => ListView(
                padding: moeUnderBarPadding(context, EdgeInsets.all(16)),
                children: [
                  Text(
                    '选择要导出的数据类型',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),

                  const Text(transferCoverageNotice),
                  const SizedBox(height: 16),

                  // Scope 选择
                  MoeSettingsGroup(
                    margin: EdgeInsets.zero,
                    children: [
                      _buildScopeItem(
                        context,
                        ref,
                        scope: SyncScope.characterCards,
                        icon: LucideIcons.userCircle,
                        isSelected: options.scopes.contains(
                          SyncScope.characterCards,
                        ),
                      ),
                      _buildScopeItem(
                        context,
                        ref,
                        scope: SyncScope.chatHistory,
                        icon: LucideIcons.messageSquare,
                        isSelected: options.scopes.contains(
                          SyncScope.chatHistory,
                        ),
                      ),
                      _buildScopeItem(
                        context,
                        ref,
                        scope: SyncScope.characterSettings,
                        icon: LucideIcons.settings,
                        isSelected: options.scopes.contains(
                          SyncScope.characterSettings,
                        ),
                      ),
                      _buildScopeItem(
                        context,
                        ref,
                        scope: SyncScope.memory,
                        icon: LucideIcons.brain,
                        isSelected: options.scopes.contains(SyncScope.memory),
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),

                  // 媒体选项
                  Text(
                    '媒体文件',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: MoeFontWeights.emphasis,
                    ),
                  ),
                  const SizedBox(height: 12),
                  MoeSettingsGroup(
                    margin: EdgeInsets.zero,
                    children: [
                      MoeSettingsRow(
                        icon: LucideIcons.image,
                        label: '包含图片',
                        trailingType: MoeSettingsRowTrailing.switchControl,
                        switchValue: options.includeImages,
                        onSwitchChanged: (value) {
                          ref
                              .read(exportOptionsProvider.notifier)
                              .setIncludeImages(value);
                        },
                      ),
                      MoeSettingsRow(
                        icon: LucideIcons.mic,
                        label: '包含语音',
                        trailingType: MoeSettingsRowTrailing.switchControl,
                        switchValue: options.includeAudio,
                        onSwitchChanged: (value) {
                          ref
                              .read(exportOptionsProvider.notifier)
                              .setIncludeAudio(value);
                        },
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),

                  // 提示
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: MoeG2Decoration(
                      radius: 8,
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          LucideIcons.info,
                          size: 16,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '包含媒体文件会增加导出文件体积',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 底部按钮
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: MoePrimaryButton(
                onPressed: options.scopes.isEmpty
                    ? null
                    : () {
                        Navigator.of(context).push(
                          ParallaxSlidePageRoute(
                            page: const ExportCharacterPage(),
                          ),
                        );
                      },
                label: '下一步：选择角色',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScopeItem(
    BuildContext context,
    WidgetRef ref, {
    required String scope,
    required IconData icon,
    required bool isSelected,
  }) {
    return MoeSettingsRow(
      icon: icon,
      label: SyncScope.getDisplayName(scope),
      subtitle: SyncScope.getDescription(scope),
      trailingType: MoeSettingsRowTrailing.custom,
      trailing: MoeCheckbox(
        value: isSelected,
        onChanged: (value) {
          ref.read(exportOptionsProvider.notifier).toggleScope(scope);
        },
      ),
      onTap: () {
        ref.read(exportOptionsProvider.notifier).toggleScope(scope);
      },
    );
  }
}

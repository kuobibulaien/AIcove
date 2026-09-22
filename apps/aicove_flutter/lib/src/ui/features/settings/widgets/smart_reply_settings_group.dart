import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../shared/widgets/index.dart';

class SmartReplySettingsGroup extends ConsumerWidget {
  const SmartReplySettingsGroup({super.key, required this.settings});
  final AppSettings settings;

  Future<void> _save(BuildContext context, Future<void> operation) async {
    try {
      await operation;
    } catch (_) {
      if (context.mounted) MoeToast.error(context, '辅助回答设置保存失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final model = settings.smartReplyModel;
    return MoeSettingsGroup(
      title: '辅助回答',
      children: [
        MoeSettingsRow(
          label: '辅助回答',
          subtitle: '点聊天气泡生成 3 条回复，选中后填入输入框',
          trailingType: MoeSettingsRowTrailing.switchControl,
          switchValue: settings.smartReplyEnabled,
          onSwitchChanged: (value) => _save(
            context,
            ref.read(appSettingsProvider.notifier).setSmartReplyEnabled(value),
          ),
        ),
        MoeSettingsRow(
          label: '辅助模型',
          subtitle: model.isEmpty
              ? '请选择便宜、快速的聊天模型'
              : settings.getModelDisplayName(model),
          onTap: () => showMoeActionSheet(
            context: context,
            title: '选择辅助模型',
            description: '独立于聊天模型，仅在点击气泡时调用',
            actions: [
              MoeSheetAction(
                icon: Icons.clear_rounded,
                label: '暂不选择',
                onTap: () => _save(
                  context,
                  ref.read(appSettingsProvider.notifier).setSmartReplyModel(''),
                ),
              ),
              for (final provider in settings.providers.where((p) => p.enabled))
                for (final id in provider.visibleModels.toSet())
                  if (settings.getModelType(
                        settings.buildModelRef(provider.id, id),
                      ) ==
                      ModelType.chat)
                    MoeSheetAction(
                      icon: model == settings.buildModelRef(provider.id, id)
                          ? Icons.check_circle
                          : Icons.circle_outlined,
                      label: settings.getModelDisplayName(
                        settings.buildModelRef(provider.id, id),
                      ),
                      subtitle: provider.displayName ?? provider.id,
                      onTap: () => _save(
                        context,
                        ref
                            .read(appSettingsProvider.notifier)
                            .setSmartReplyModel(
                              settings.buildModelRef(provider.id, id),
                            ),
                      ),
                    ),
            ],
            showCancelButton: true,
          ),
        ),
      ],
    );
  }
}

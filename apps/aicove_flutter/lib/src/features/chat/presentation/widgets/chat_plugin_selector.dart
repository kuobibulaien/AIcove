import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../settings/app_settings.dart';
import '../../../../ui/features/settings/pages/chat_plugin_settings_page.dart';

Future<void> showChatPluginSelector({
  required BuildContext context,
  required WidgetRef ref,
  required List<String>? enabledPlugins,
  required Future<void> Function(List<String>?) onChanged,
}) async {
  final selected = enabledPlugins == null
      ? conversationScopedChatPluginItems.map((item) => item.id).toSet()
      : enabledPlugins
            .where(
              (id) => conversationScopedChatPluginItems.any(
                (item) => item.id == id,
              ),
            )
            .toSet();
  await showModalBottomSheet<void>(
    context: context,
    useRootNavigator: false,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    isDismissible: false,
    enableDrag: false,
    builder: (_) => _PluginSelectorSheet(
      ref: ref,
      initialSelected: selected,
      onConfirm: (value) => onChanged(
        value.length == conversationScopedChatPluginItems.length
            ? null
            : value.toList(),
      ),
    ),
  );
}

/// 插件选择底部弹窗
class _PluginSelectorSheet extends StatefulWidget {
  final WidgetRef ref;
  final Set<String> initialSelected;
  final Future<void> Function(Set<String>) onConfirm;

  const _PluginSelectorSheet({
    required this.ref,
    required this.initialSelected,
    required this.onConfirm,
  });

  @override
  State<_PluginSelectorSheet> createState() => _PluginSelectorSheetState();
}

class _PluginSelectorSheetState extends State<_PluginSelectorSheet>
    with MoeAutoSaveState<_PluginSelectorSheet> {
  late Set<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = Set.from(widget.initialSelected);
    autoSave.configure(
      save: () => widget.onConfirm(Set<String>.from(_selected)),
      snapshot: () => moeAutoSaveSignature(_selected.toList()..sort()),
    );
  }

  /// 普通聊天插件恒为全局开启，仅主动关怀仍受全局服务开关约束。
  bool _isPluginGlobalEnabled(String pluginId) {
    if (pluginId != 'trigger') return true;
    return widget.ref
            .read(appSettingsProvider)
            .value
            ?.autoReplySettings
            .enabled ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    return autoSavePage(
      MoeBottomSheet(
        title: '插件设置',
        showCloseButton: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: conversationScopedChatPluginItems.length,
                itemBuilder: (context, index) {
                  final item = conversationScopedChatPluginItems[index];
                  final enabled = _isPluginGlobalEnabled(item.id);
                  return MoeSettingsRow(
                    icon: item.icon,
                    label: item.name,
                    subtitle: enabled ? null : '全局未开启，需先在聊天插件中启用',
                    enabled: enabled,
                    trailingType: MoeSettingsRowTrailing.switchControl,
                    switchValue: _selected.contains(item.id),
                    onSwitchChanged: enabled
                        ? (value) => setState(() {
                            if (value) {
                              _selected.add(item.id);
                            } else {
                              _selected.remove(item.id);
                            }
                          })
                        : null,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

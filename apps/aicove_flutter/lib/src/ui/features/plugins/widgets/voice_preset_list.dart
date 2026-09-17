import '../../../shared/widgets/moe_search_field.dart';
import '../../../shared/widgets/list/moe_settings_group.dart';
import 'package:flutter/material.dart';
import '../../../../features/plugins/tts/tts_config.dart';
import '../../../theme/tokens.dart';

/// Shared, lazy preset library for plugin management and role binding.
class VoicePresetList extends StatefulWidget {
  const VoicePresetList({
    super.key,
    required this.presets,
    required this.onSelect,
    this.providerNames = const {},
    this.selectedId,
    this.defaultId,
    this.allowDefault = false,
    this.header,
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 24),
  });
  final List<VoicePreset> presets;
  final Map<String, String> providerNames;
  final String? selectedId;
  final String? defaultId;
  final bool allowDefault;

  final Widget? header;
  final EdgeInsetsGeometry padding;
  final ValueChanged<VoicePreset?> onSelect;

  @override
  State<VoicePresetList> createState() => _VoicePresetListState();
}

class _VoicePresetListState extends State<VoicePresetList> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
  }

  String _provider(VoicePreset preset) {
    final id = preset.synthesis?.providerId;
    if (id == null) return '待完善';
    final name = widget.providerNames[id];
    if (name == null) return '$id（检查渠道）';
    return widget.providerNames.values.where((value) => value == name).length >
            1
        ? '$name · $id'
        : name;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final filtered =
        widget.presets
            .where(
              (p) =>
                  '${p.name} ${_provider(p)} ${p.synthesis?.modelId ?? ''} ${p.synthesis?.voiceId ?? ''}'
                      .toLowerCase()
                      .contains(_searchController.text.trim().toLowerCase()),
            )
            .toList()
          ..sort((a, b) {
            final group = (a.synthesis?.providerId ?? '~').compareTo(
              b.synthesis?.providerId ?? '~',
            );
            return group == 0 ? a.name.compareTo(b.name) : group;
          });
    final rows = <Object>[];
    String? lastGroup;
    for (final preset in filtered) {
      final group = preset.synthesis?.providerId ?? '~pending';
      if (lastGroup != group) {
        rows.add(_provider(preset));
        lastGroup = group;
      }
      rows.add(preset);
    }
    final entries = <Object>[
      if (widget.header != null) _VoiceListHeader(widget.header!),
      _VoiceListSlot.search,
      if (widget.allowDefault) _VoiceListSlot.defaultTile,
      if (rows.isEmpty) _VoiceListSlot.empty else ...rows,
    ];
    return CustomScrollView(
      key: const ValueKey('voice-preset-list'),
      slivers: [
        SliverPadding(
          padding: widget.padding,
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              if (index.isOdd) {
                return const SizedBox(height: MoeSettingsLayout.sectionGap);
              }
              final entry = entries[index ~/ 2];
              if (entry is _VoiceListHeader) return entry.child;
              if (entry == _VoiceListSlot.search) {
                return MoeSearchField(
                  padding: EdgeInsets.zero,
                  key: const ValueKey('voice-preset-search'),
                  controller: _searchController,
                  hintText: '搜索预设、渠道或模型',
                );
              }
              if (entry == _VoiceListSlot.defaultTile) {
                return MoeSettingsGroup(
                  children: [
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                      ),
                      title: const Text('使用默认预设'),
                      subtitle: Text(
                        widget.presets
                                .where((p) => p.id == widget.defaultId)
                                .firstOrNull
                                ?.name ??
                            '尚未设置默认预设',
                      ),
                      trailing: widget.selectedId == null
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () => widget.onSelect(null),
                    ),
                  ],
                );
              }
              if (entry == _VoiceListSlot.empty) {
                return MoeSettingsGroup(
                  padding: MoeSettingsLayout.contentPadding,
                  children: [
                    Text(
                      _searchController.text.isEmpty
                          ? '还没有音色预设\n点击“新建预设”开始'
                          : '没有匹配的预设',
                      textAlign: TextAlign.center,
                    ),
                  ],
                );
              }
              if (entry is String) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                  child: Text(
                    entry,
                    style: TextStyle(
                      color: colors.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                );
              }
              final preset = entry as VoicePreset;
              final synthesis = preset.synthesis;
              return MoeSettingsGroup(
                children: [
                  ListTile(
                    key: ValueKey('voice-preset-${preset.id}'),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                    title: Text(preset.name),
                    subtitle: Text(
                      synthesis == null
                          ? '待完善渠道与模型 · 原素材已保留'
                          : '${synthesis.modelId}\n${preset.id == widget.defaultId ? '默认预设 · ' : ''}${synthesis.voiceId?.isNotEmpty == true ? '音色 ID' : '参考音频'} · 语速 ${synthesis.speed}×',
                    ),
                    trailing: Icon(
                      widget.selectedId == preset.id
                          ? Icons.check_circle
                          : Icons.chevron_right,
                    ),
                    onTap: () => widget.onSelect(preset),
                  ),
                ],
              );
            }, childCount: entries.isEmpty ? 0 : entries.length * 2 - 1),
          ),
        ),
      ],
    );
  }
}

enum _VoiceListSlot { search, defaultTile, empty }

class _VoiceListHeader {
  const _VoiceListHeader(this.child);
  final Widget child;
}

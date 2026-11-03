/// RoleExtraPromptPage - 角色编辑页「附加提示词」
///
/// 一页内编辑补充在角色提示词之后的设定，以及角色的生图提示词与生图方案。
/// 数据由角色编辑页持有，本页只编辑传入的输入框并回调方案选择。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/plugins/prompts/prompt_pack_store.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';
import '../../plugins/pages/prompt_pack_pages.dart';
import '../widgets/role_prompt_section.dart';

class RoleExtraPromptPage extends ConsumerStatefulWidget {
  const RoleExtraPromptPage({
    super.key,
    required this.extraPromptController,
    required this.extraPromptHint,
    required this.drawingPromptController,
    required this.initialPackId,
    required this.drawingPersonaPrompt,
    required this.onPackChanged,
  });

  final TextEditingController extraPromptController;
  final String extraPromptHint;
  final TextEditingController drawingPromptController;
  final String? initialPackId;
  final String drawingPersonaPrompt;
  final ValueChanged<String?> onPackChanged;

  @override
  ConsumerState<RoleExtraPromptPage> createState() =>
      _RoleExtraPromptPageState();
}

class _RoleExtraPromptPageState extends ConsumerState<RoleExtraPromptPage> {
  late String? _selectedPackId = widget.initialPackId?.trim().isEmpty == true
      ? null
      : widget.initialPackId?.trim();

  void _selectPack(String? packId) {
    setState(() => _selectedPackId = packId);
    widget.onPackChanged(packId);
  }

  @override
  Widget build(BuildContext context) {
    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const MoeAppBar(title: '附加提示词', showBackButton: true),
      body: Builder(
        builder: (context) => SingleChildScrollView(
          padding: moeUnderBarPadding(context),
          physics: const BouncingScrollPhysics(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            child: _buildContent(context),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final colors = context.moeColors;
    final library =
        ref.watch(promptPackProvider).valueOrNull?.library ??
        PromptPackState.initial().library;
    final packs = library.packsFor('image');
    final defaultPack = resolveDefaultRoleDrawingPack(
      ref: ref,
      library: library,
      drawingPersonaPrompt: widget.drawingPersonaPrompt,
    );
    final activePackId =
        (_selectedPackId != null && library.byId(_selectedPackId!) != null)
        ? _selectedPackId!
        : defaultPack.id;
    final activePack = library.byId(activePackId) ?? defaultPack;
    final currentFormat = resolveRoleDrawingFormat(
      ref: ref,
      drawingPersonaPrompt: widget.drawingPersonaPrompt,
    );
    final incompatibleHint = !activePack.isCompatibleWithImageFormat(
      currentFormat,
    )
        ? switch (activePack.requiredImageFormat) {
            'novelai' => '当前方案需配合 NovelAI 渠道的画风预设使用，请在角色编辑页切换画风预设。',
            'comfyui' => '当前方案需配合 ComfyUI 渠道的画风预设使用，请在角色编辑页切换画风预设。',
            _ => null,
          }
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MoeSettingsGroup(
          title: '补充设定',
          titleFirst: true,
          margin: EdgeInsets.zero,
          padding: MoeSettingsLayout.contentPadding,
          children: [
            MoeTextField(
              controller: widget.extraPromptController,
              hint: widget.extraPromptHint,
              minLines: 6,
              maxLines: 14,
            ),
          ],
        ),
        const SizedBox(height: 16),
        MoeSettingsGroup(
          title: '生图提示词',
          titleFirst: true,
          margin: EdgeInsets.zero,
          padding: MoeSettingsLayout.contentPadding,
          children: [
            MoeTextField(
              controller: widget.drawingPromptController,
              hint: '填写角色的外貌标签、固定穿搭或画面要求（如：nahida_(genshin_impact)）',
              minLines: 3,
              maxLines: 6,
            ),
          ],
        ),
        const SizedBox(height: 16),
        MoeSettingsGroup(
          title: '生图方案（与画风预设自由组合）',
          titleFirst: true,
          margin: EdgeInsets.zero,
          children: [
            for (var i = 0; i < packs.length; i++)
              MoeSettingsRow(
                label: packs[i].name,
                subtitle: packs[i].description.isNotEmpty
                    ? packs[i].description
                    : (packs[i].builtIn ? '内置方案' : '自建方案'),
                showDivider: i < packs.length - 1,
                trailingType: activePackId == packs[i].id
                    ? MoeSettingsRowTrailing.custom
                    : MoeSettingsRowTrailing.none,
                trailing: activePackId == packs[i].id
                    ? Icon(Icons.check, color: colors.primary)
                    : null,
                onTap: () => _selectPack(
                  packs[i].id == defaultPack.id ? null : packs[i].id,
                ),
              ),
          ],
        ),
        if (incompatibleHint != null)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 4, right: 4),
            child: Text(
              incompatibleHint,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: MoeSecondaryButton(
            label: '管理生图方案',
            icon: Icons.tune_rounded,
            size: MoeSecondaryButtonSize.sm,
            onPressed: () {
              Navigator.of(context).push(
                ParallaxSlidePageRoute(
                  page: const PromptPackListPage(pluginId: 'image'),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

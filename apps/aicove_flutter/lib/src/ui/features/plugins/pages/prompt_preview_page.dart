import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../features/plugins/prompts/prompt_pack.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

/// The final text a preset sends to the model, per scope, rendered with the
/// preset's own values (ADR0092).
class PromptPreviewPage extends StatelessWidget {
  const PromptPreviewPage({
    super.key,
    required this.pluginId,
    required this.resolved,
    required this.variables,
  });

  final String pluginId;
  final ResolvedPromptPack resolved;
  final Map<String, Object?> variables;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final scopes = PromptScopes.of(pluginId);
    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(title: '最终提示词', showBackButton: true),
      body: Builder(
        builder: (context) => ListView(
          padding: moeUnderBarPadding(
            context,
            const EdgeInsets.fromLTRB(16, 12, 16, 24),
          ),
          children: [
            Text(
              '提示词包：${resolved.pack.name}${resolved.automatic ? '（自动匹配）' : ''}',
              style: TextStyle(fontSize: 13, color: colors.textSecondary),
            ),
            const SizedBox(height: 12),
            for (final scope in scopes.entries)
              _ScopeBlock(
                title: scope.value,
                text: resolved.render(scope.key, variables),
              ),
          ],
        ),
      ),
    );
  }
}

class _ScopeBlock extends StatelessWidget {
  const _ScopeBlock({required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: MoeFontWeights.emphasis,
                    color: colors.text,
                  ),
                ),
              ),
              if (text.isNotEmpty)
                MoeIconButton(
                  icon: Icons.copy_outlined,
                  tooltip: '复制',
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: text));
                    MoeToast.success(context, '已复制');
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),
          // Prose, so it wraps instead of scrolling sideways like code.
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colors.surfaceAlt,
              borderRadius: BorderRadius.circular(MoeSettingsLayout.cardRadius),
            ),
            child: SelectableText(
              text.isEmpty ? '（这里不发送任何说明）' : text,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: text.isEmpty ? colors.muted : colors.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

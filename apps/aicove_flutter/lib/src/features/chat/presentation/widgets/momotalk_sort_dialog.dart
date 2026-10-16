import 'package:flutter/material.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';
import '../../domain/sort_mode.dart';

class MomotalkSortDialog extends StatelessWidget {
  final SortMode currentMode;
  final ValueChanged<SortMode> onModeChanged;

  const MomotalkSortDialog({
    super.key,
    required this.currentMode,
    required this.onModeChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: SizedBox(
        width: 300,
        child: MoeFloatingSurface(
          baseline: MoeMaterialBaseline.background,
          radius: 24,
          solidColor: colors.componentBackground,
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Title Row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '排列',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: MoeFontWeights.emphasis,
                      color: colors.text,
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: colors.muted),
                    onPressed: () => Navigator.of(context).pop(),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Options Grid
              Row(
                children: [
                  Expanded(
                    child: _buildOptionButton(
                      context,
                      label: '最新消息',
                      isSelected: currentMode == SortMode.latest,
                      onTap: () => onModeChanged(SortMode.latest),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildOptionButton(
                      context,
                      label: '名字',
                      isSelected: currentMode == SortMode.name,
                      onTap: () => onModeChanged(SortMode.name),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Placeholder options for visual consistency with reference (disabled)
              Row(
                children: [
                  Expanded(
                    child: _buildOptionButton(
                      context,
                      label: '羈絆等級',
                      isSelected: false,
                      onTap: null, // Disabled
                      isPlaceholder: true,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildOptionButton(
                      context,
                      label: '精選',
                      isSelected: false,
                      onTap: null, // Disabled
                      isPlaceholder: true,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // Confirm Button
              MoePrimaryButton(
                label: '確認',
                width: double.infinity,
                borderRadius: BorderRadius.circular(12),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOptionButton(
    BuildContext context, {
    required String label,
    required bool isSelected,
    required VoidCallback? onTap,
    bool isPlaceholder = false,
  }) {
    return MoeChoiceChip(
      label: label,
      selected: isSelected,
      expand: true,
      muted: isPlaceholder,
      size: MoeChoiceChipSize.md,
      onTap: onTap,
    );
  }
}

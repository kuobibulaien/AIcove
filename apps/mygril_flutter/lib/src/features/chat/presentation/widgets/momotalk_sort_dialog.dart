import 'package:flutter/material.dart';
import '../../../../core/theme/tokens.dart';

enum SortMode {
  latest,
  name,
}

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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      backgroundColor: colors.surface,
      child: Container(
        width: 300,
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
                    fontWeight: FontWeight.bold,
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
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: ElevatedButton.styleFrom(
                backgroundColor: colors.surface,
                foregroundColor: const Color(0xFF4C5B6F), // Dark blue text
                elevation: 0,
                side: BorderSide(color: colors.divider),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text(
                '確認',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
          ],
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
    final colors = context.moeColors;
    
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFFC879B) : colors.surface, // Pink if selected
          border: Border.all(
            color: isSelected ? const Color(0xFFFC879B) : colors.divider,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : (isPlaceholder ? colors.muted : colors.text),
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}

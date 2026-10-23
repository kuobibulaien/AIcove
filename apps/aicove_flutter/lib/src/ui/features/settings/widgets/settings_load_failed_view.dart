import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/settings/app_settings.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

/// Shown in place of the app when the settings do not load. Resetting the
/// interface settings writes storage directly: they cannot be read as
/// [AppSettings] here.
class SettingsLoadFailedView extends ConsumerStatefulWidget {
  const SettingsLoadFailedView({super.key});

  @override
  ConsumerState<SettingsLoadFailedView> createState() =>
      _SettingsLoadFailedViewState();
}

class _SettingsLoadFailedViewState
    extends ConsumerState<SettingsLoadFailedView> {
  bool _resetting = false;
  bool _failed = false;

  Future<void> _reset() async {
    setState(() {
      _resetting = true;
      _failed = false;
    });
    try {
      await resetStoredInterfaceSettings();
      ref.invalidate(appSettingsProvider);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _resetting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(MoeSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '加载设置失败',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: MoeFontWeights.emphasis,
                  color: colors.text,
                ),
              ),
              const SizedBox(height: MoeSpacing.sm),
              Text(
                _failed
                    ? '没能恢复，请重试'
                    : '可以把界面设置恢复成默认后再打开，聊天记录、角色、模型和渠道都不受影响。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: colors.textSecondary),
              ),
              const SizedBox(height: MoeSpacing.lg),
              MoePrimaryButton(
                label: '恢复默认界面设置',
                isLoading: _resetting,
                onPressed: _resetting ? null : _reset,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

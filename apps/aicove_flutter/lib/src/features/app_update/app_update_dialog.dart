import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../ui/shared/widgets/meotalk_dialog.dart';
import '../../ui/shared/widgets/moe_toast.dart';
import '../../ui/theme/tokens.dart';
import 'app_update_service.dart';

enum _UpdateAction { download, later, skip }

/// Shows the update prompt with download / later / skip-this-version actions.
Future<void> showAppUpdateDialog(
  BuildContext context,
  AppRelease release, {
  String currentVersion = kAppReleaseTag,
}) async {
  final colors = context.moeColors;
  final action = await showDialog<_UpdateAction>(
    context: context,
    barrierColor: Colors.transparent,
    builder: (dialogContext) => MeoTalkDialog(
      title: '发现新版本',
      titleActionText: '跳过此版本',
      onTitleAction: () =>
          Navigator.of(dialogContext).pop(_UpdateAction.skip),
      cancelText: '稍后',
      confirmText: '前往下载',
      onCancel: () => Navigator.of(dialogContext).pop(_UpdateAction.later),
      onConfirm: () =>
          Navigator.of(dialogContext).pop(_UpdateAction.download),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${release.version}（当前 $currentVersion）',
            style: TextStyle(
              fontSize: 15,
              fontWeight: MoeFontWeights.emphasis,
              color: colors.text,
            ),
          ),
          if (release.highlights.isNotEmpty) const SizedBox(height: 8),
          for (final item in release.highlights) Text('· $item'),
        ],
      ),
    ),
  );
  switch (action) {
    case _UpdateAction.skip:
      await AppUpdateService.skipVersion(release.version);
    case _UpdateAction.download:
      final opened = await launchUrl(
        Uri.parse(release.url),
        mode: LaunchMode.externalApplication,
      ).catchError((_) => false);
      if (!opened && context.mounted) {
        MoeToast.show(context, '无法打开链接：${release.url}',
            type: ToastType.error);
      }
    case _UpdateAction.later || null:
      break;
  }
}

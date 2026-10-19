import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../ui/shared/widgets/meotalk_dialog.dart';
import '../../ui/shared/widgets/moe_toast.dart';
import '../../ui/theme/tokens.dart';
import 'app_update_service.dart';

/// Wording for the installed version in the prompt; a development build has no
/// release tag, so its numeric core is shown instead.
String describeInstalledVersion(String installed, {String? numeric}) {
  final tag = installed.trim();
  if (RegExp(r'^v?\d+\.\d+\.\d+').hasMatch(tag)) {
    return tag.startsWith('v') ? tag.substring(1) : tag;
  }
  final core = numeric?.trim() ?? '';
  return core.isEmpty ? '开发版本' : '开发版 $core';
}

enum _UpdateAction { download, later, skip }

/// Shows the update prompt with download / later / skip-this-version actions.
Future<void> showAppUpdateDialog(
  BuildContext context,
  AppRelease release, {
  String currentVersion = kAppReleaseTag,
  String? numericVersion,
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
            '${release.version}（当前 '
            '${describeInstalledVersion(currentVersion, numeric: numericVersion)}）',
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

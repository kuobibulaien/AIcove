/// One-off "author's note" shown after installing a specific release.
///
/// Only the build whose `AICOVE_RELEASE_TAG` equals [ReleaseAnnouncement.tag]
/// shows it, once per install. Development builds have no tag and never show
/// it; later releases simply ship a different (or no) announcement.
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../ui/shared/widgets/meotalk_dialog.dart';
import '../../ui/theme/tokens.dart';
import 'app_update_service.dart';

class ReleaseAnnouncement {
  const ReleaseAnnouncement({
    required this.tag,
    required this.title,
    required this.paragraphs,
  });

  /// Release version without the `v` prefix, e.g. `0.2.0-test.5`.
  final String tag;
  final String title;
  final List<String> paragraphs;
}

/// The announcement bundled with the upcoming release; set to null when the
/// next release has nothing to say.
// ignore: unnecessary_nullable_for_final_variable_declarations
const ReleaseAnnouncement? kReleaseAnnouncement = ReleaseAnnouncement(
  tag: '0.2.0-test.5',
  title: '作者的话',
  paragraphs: [
    '语音功能基本开发完了，现在可以和角色打语音电话啦。',
    '作者自己用的是 Fish Audio 的免费 API，大家可以试试：在「设置 · 模型」里进入 Fish Audio 渠道，点「获取 API key」申请后填进去即可。',
    '记得还要在「设置 · 插件 · 语音设置 · 语音通话」里配置语音识别选项，否则电话打不通哦。',
  ],
);

const _seenKey = 'release_announcement_seen_tag';

/// Returns the announcement to show for [installedTag], or null when there is
/// none, the tag does not match, or it has already been shown.
Future<ReleaseAnnouncement?> pendingReleaseAnnouncement({
  String installedTag = kAppReleaseTag,
  ReleaseAnnouncement? announcement = kReleaseAnnouncement,
}) async {
  if (announcement == null || installedTag != announcement.tag) return null;
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getString(_seenKey) == announcement.tag) return null;
  return announcement;
}

Future<void> markReleaseAnnouncementSeen(ReleaseAnnouncement announcement) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_seenKey, announcement.tag);
}

/// Shows [announcement] and records it as seen once the dialog closes.
Future<void> showReleaseAnnouncementDialog(
  BuildContext context,
  ReleaseAnnouncement announcement,
) async {
  final colors = context.moeColors;
  await showMeoTalkDialog(
    context: context,
    title: announcement.title,
    showCancelButton: false,
    confirmText: '知道了',
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (index, text) in announcement.paragraphs.indexed) ...[
          if (index > 0) const SizedBox(height: 10),
          Text(
            text,
            style: TextStyle(
              fontSize: 15,
              color: colors.textSecondary,
              height: 1.5,
            ),
          ),
        ],
      ],
    ),
  );
  await markReleaseAnnouncementSeen(announcement);
}

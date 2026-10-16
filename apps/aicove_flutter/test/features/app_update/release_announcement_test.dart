import 'package:aicove_flutter/src/features/app_update/release_announcement.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const note = ReleaseAnnouncement(
    tag: '0.2.0-test.5',
    title: '作者的话',
    paragraphs: ['语音通话来啦'],
  );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('只有对应版本显示，且只显示一次', () async {
    expect(
      await pendingReleaseAnnouncement(installedTag: '', announcement: note),
      isNull,
    );
    expect(
      await pendingReleaseAnnouncement(
        installedTag: '0.2.0-test.6',
        announcement: note,
      ),
      isNull,
    );
    expect(
      await pendingReleaseAnnouncement(
        installedTag: '0.2.0-test.5',
        announcement: note,
      ),
      same(note),
    );
    await markReleaseAnnouncementSeen(note);
    expect(
      await pendingReleaseAnnouncement(
        installedTag: '0.2.0-test.5',
        announcement: note,
      ),
      isNull,
    );
  });

  test('当前打包的公告文案提到 Fish Audio 和语音识别设置', () {
    final text = kReleaseAnnouncement!.paragraphs.join();
    expect(text, contains('Fish Audio'));
    expect(text, contains('语音通话'));
  });
}

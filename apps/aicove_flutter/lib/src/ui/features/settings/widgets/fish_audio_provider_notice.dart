import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

/// 内置 Fish Audio 渠道的 id。
const kFishAudioProviderId = 'fish_audio';

/// Fish Audio 官网获取 API Key 的页面。
const kFishAudioApiKeyUrl = 'https://fish.audio/zh-CN/app/api-keys/';

/// 免费说明的失效时刻（本地时间 2026-12-01 零点起不再显示）。
final kFishAudioFreeNoticeExpiry = DateTime(2026, 12, 1);

const kFishAudioFreeNoticeText =
    'AIcove 与 Fish Audio 暂无直接关联，无意作为营销广告推广。'
    '此渠道的 s2.1-pro-free 模型目前免费，免费状态已多次延期，现已延期至 2026 年 11 月 30 日；'
    '同时支持音色克隆，故作为语音通话的推荐模型。';

/// Fish Audio 渠道详情「基础配置」里的附加内容：
/// API Key 为空时给出获取链接；限时的免费说明气泡到期后自动消失。
class FishAudioProviderNotice extends StatelessWidget {
  const FishAudioProviderNotice({
    super.key,
    required this.keyController,
    this.showKeyLink = true,
    this.now,
  });

  /// 单 Key 输入框；为空时显示获取链接。
  final TextEditingController keyController;

  /// 多 Key 模式没有单 Key 输入框，不显示链接。
  final bool showKeyLink;

  /// 测试注入的当前时间。
  final DateTime? now;

  static bool isFreeNoticeActive(DateTime now) =>
      now.isBefore(kFishAudioFreeNoticeExpiry);

  Future<void> _openApiKeyPage(BuildContext context) async {
    final opened = await launchUrl(
      Uri.parse(kFishAudioApiKeyUrl),
      mode: LaunchMode.externalApplication,
    ).catchError((_) => false);
    if (opened || !context.mounted) return;
    await showMeoTalkAlert(
      context: context,
      title: '无法打开链接',
      message: kFishAudioApiKeyUrl,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final showNotice = isFreeNoticeActive(now ?? DateTime.now());
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: keyController,
      builder: (context, value, _) {
        final showLink = showKeyLink && value.text.trim().isEmpty;
        if (!showLink && !showNotice) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showLink)
                Align(
                  alignment: Alignment.centerRight,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _openApiKeyPage(context),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        '获取 API key',
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.primary,
                          decoration: TextDecoration.underline,
                          decorationColor: colors.primary,
                        ),
                      ),
                    ),
                  ),
                ),
              if (showLink && showNotice) const SizedBox(height: 8),
              if (showNotice)
                DecoratedBox(
                  decoration: ShapeDecoration(
                    color: colors.primary.withValues(alpha: 0.08),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(MoeSmoothRadii.sm),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      kFishAudioFreeNoticeText,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

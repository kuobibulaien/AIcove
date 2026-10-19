import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../features/assistant/application/assistant_onboarding_controller.dart';
import '../../../../features/assistant/domain/assistant_onboarding.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import '../../settings/pages/add_provider_sheet.dart';

/// Scripted phase of the AIcove assistant (ADR0073): fixed lines and cards,
/// no model call. Shown in the assistant chat while no chat model is usable.
class AssistantOnboardingView extends ConsumerWidget {
  const AssistantOnboardingView({
    super.key,
    required this.displayName,
    this.avatarUrl,
    this.topPadding = 0,
  });

  final String displayName;
  final String? avatarUrl;
  final double topPadding;

  static final deepSeekKeysUrl = Uri.parse(
    'https://platform.deepseek.com/api_keys',
  );
  static final deepSeekTopUpUrl = Uri.parse(
    'https://platform.deepseek.com/top_up',
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(assistantOnboardingProvider).valueOrNull;
    if (state == null) return const SizedBox.shrink();
    final controller = ref.read(assistantOnboardingProvider.notifier);
    final step = switch (state.step) {
      OnboardingStep.experience => _ExperienceStep(controller: controller),
      OnboardingStep.chooseProvider => _ChooseProviderStep(
        controller: controller,
        experienced: state.experienced,
      ),
      OnboardingStep.getKey => _GetKeyStep(controller: controller),
      OnboardingStep.pasteKey => _PasteKeyStep(
        controller: controller,
        experienced: state.experienced,
      ),
      OnboardingStep.otherProvider => _OtherProviderStep(
        controller: controller,
      ),
    };
    return ListView(
      key: ValueKey('assistant-onboarding-${state.step.name}'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(
        16,
        topPadding + 12,
        16,
        MediaQuery.paddingOf(context).bottom + 24,
      ),
      children: [
        _AssistantLine.avatarRow(
          displayName: displayName,
          avatarUrl: avatarUrl,
        ),
        step,
      ],
    );
  }
}

/// One assistant speech bubble, indented under the avatar.
class _AssistantLine extends StatelessWidget {
  const _AssistantLine(this.text);

  final String text;

  static Widget avatarRow({required String displayName, String? avatarUrl}) =>
      Builder(
        builder: (context) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              MoeAvatar(name: displayName, avatarUrl: avatarUrl, size: 32),
              const SizedBox(width: 8),
              Text(
                displayName,
                style: TextStyle(
                  fontSize: 14,
                  color: context.moeColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, right: 32),
      child: Align(
        alignment: Alignment.centerLeft,
        child: MoeContentSurface(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Text(
              text,
              style: TextStyle(fontSize: 15, height: 1.5, color: colors.text),
            ),
          ),
        ),
      ),
    );
  }
}

/// Answer buttons under the assistant lines, stacked full width.
class _Choices extends StatelessWidget {
  const _Choices(this.children);

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final child in children)
          Padding(padding: const EdgeInsets.only(bottom: 8), child: child),
      ],
    ),
  );
}

/// A collapsed beginner question that unfolds in place.
class _Explain extends StatefulWidget {
  const _Explain({required this.question, required this.answer});

  final String question;
  final String answer;

  @override
  State<_Explain> createState() => _ExplainState();
}

class _ExplainState extends State<_Explain> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, right: 32),
      child: MoeContentSurface(
        child: InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.question,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: MoeFontWeights.emphasis,
                          color: colors.text,
                        ),
                      ),
                    ),
                    Icon(
                      _open ? Icons.expand_less : Icons.expand_more,
                      size: 20,
                      color: colors.muted,
                    ),
                  ],
                ),
                if (_open) ...[
                  const SizedBox(height: 6),
                  Text(
                    widget.answer,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.5,
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BackLink extends StatelessWidget {
  const _BackLink({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton(onPressed: onTap, child: const Text('返回上一步')),
  );
}

Future<void> _openExternal(BuildContext context, Uri url) async {
  final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
  if (!opened && context.mounted) {
    await Clipboard.setData(ClipboardData(text: url.toString()));
    if (context.mounted) MoeToast.show(context, '打不开浏览器，网址已复制');
  }
}

String keyCheckFailureMessage(KeyCheckFailure failure) => switch (failure) {
  KeyCheckFailure.invalidKey => '这个 Key 不对：可能复制漏了几位，或者已经被删除。重新复制一次再粘贴试试。',
  KeyCheckFailure.insufficientBalance => 'Key 是对的，但账户余额不足，充值后再试一次。',
  KeyCheckFailure.network => '连不上模型服务，检查一下网络（或代理）后再试。',
  KeyCheckFailure.other => '测试没通过，可能是模型或接口地址不对。可以稍后再试，或者换一家。',
};

class _ExperienceStep extends StatelessWidget {
  const _ExperienceStep({required this.controller});

  final AssistantOnboardingController controller;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _AssistantLine('你好，我是 AIcove 助手。先花一两分钟把 AI 接上，之后有什么不会的都可以问我。'),
      const _AssistantLine('你之前配置过 API、用过 AI Agent 吗？'),
      _Choices([
        MoePrimaryButton(
          label: '完全没有，带我一步步来',
          onPressed: () => controller.chooseExperience(experienced: false),
        ),
        MoeSecondaryButton(
          label: '配过 API，直接填 Key',
          onPressed: () => controller.chooseExperience(experienced: true),
        ),
        MoeSecondaryButton(label: '都会，跳过全部教程', onPressed: controller.skipAll),
      ]),
    ],
  );
}

class _ChooseProviderStep extends StatelessWidget {
  const _ChooseProviderStep({
    required this.controller,
    required this.experienced,
  });

  final AssistantOnboardingController controller;
  final bool experienced;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (!experienced) ...[
        const _AssistantLine(
          'AIcove 本身不带 AI，要接上一家「模型服务」才能聊天。'
          '可以这样理解：AIcove 是手机，模型服务是电话卡。',
        ),
        const _Explain(
          question: 'API 是什么？',
          answer:
              'API 是程序之间互相「点单」的窗口。AIcove 把你说的话通过 API 发给模型服务，'
              '模型想好回复再传回来。你不用懂细节，接上就能用。',
        ),
        const _Explain(
          question: 'Key 是什么？',
          answer:
              'Key 是模型服务发给你的「专属钥匙」，一串以 sk- 开头的字符。'
              '用量和费用都记在这把钥匙上，所以别发给别人。它只保存在你的设备上。',
        ),
        const _AssistantLine('推荐 DeepSeek：国内直接能用、按用量付费，聊天很便宜。'),
      ] else
        const _AssistantLine('用哪家模型服务？'),
      _Choices([
        MoePrimaryButton(
          label: 'DeepSeek（推荐）',
          onPressed: controller.chooseRecommended,
        ),
        MoeSecondaryButton(label: '其他家', onPressed: controller.chooseOther),
      ]),
      _BackLink(onTap: () => controller.goTo(OnboardingStep.experience)),
    ],
  );
}

class _GetKeyStep extends StatelessWidget {
  const _GetKeyStep({required this.controller});

  final AssistantOnboardingController controller;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _AssistantLine(
        '跟着这几步拿到 Key：\n'
        '1. 点下面的按钮打开 DeepSeek 开放平台，注册并登录。\n'
        '2. 在「充值」页充一点钱，按用量扣费，日常聊天很省。\n'
        '3. 打开「API Keys」，点「创建 API Key」，名字随便填。\n'
        '4. 复制生成的 Key（sk- 开头）。它只显示这一次，复制好再关掉窗口。',
      ),
      _Choices([
        MoePrimaryButton(
          label: '打开 DeepSeek 开放平台',
          icon: Icons.open_in_new_rounded,
          onPressed: () =>
              _openExternal(context, AssistantOnboardingView.deepSeekKeysUrl),
        ),
        MoeSecondaryButton(
          label: '我复制好了',
          onPressed: () => controller.goTo(OnboardingStep.pasteKey),
        ),
      ]),
      _BackLink(onTap: () => controller.goTo(OnboardingStep.chooseProvider)),
    ],
  );
}

class _PasteKeyStep extends StatefulWidget {
  const _PasteKeyStep({required this.controller, required this.experienced});

  final AssistantOnboardingController controller;
  final bool experienced;

  @override
  State<_PasteKeyStep> createState() => _PasteKeyStepState();
}

class _PasteKeyStepState extends State<_PasteKeyStep> {
  final _keyCtrl = TextEditingController();
  var _checking = false;
  var _obscure = true;
  KeyCheckFailure? _failure;

  @override
  void dispose() {
    _keyCtrl.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      if (mounted) MoeToast.show(context, '剪贴板是空的，先去复制 Key');
      return;
    }
    setState(() {
      _keyCtrl.text = text;
      _failure = null;
    });
  }

  Future<void> _submit() async {
    if (_keyCtrl.text.trim().isEmpty) {
      MoeToast.show(context, '先把 Key 粘贴进来');
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _checking = true;
      _failure = null;
    });
    final failure = await widget.controller.submitRecommendedKey(_keyCtrl.text);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _failure = failure;
    });
  }

  @override
  Widget build(BuildContext context) {
    final failure = _failure;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AssistantLine(
          widget.experienced
              ? '把 DeepSeek 的 API Key 粘贴到下面，我先试一下能不能用。'
              : '把刚复制的 Key 粘贴到下面，我先帮你试一下能不能用。',
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 8),
          child: MoeTextField(
            key: const ValueKey('assistant-onboarding-key-field'),
            controller: _keyCtrl,
            hint: 'sk-...',
            obscureText: _obscure,
            enabled: !_checking,
            onChanged: (_) {
              if (_failure != null) setState(() => _failure = null);
            },
            suffix: IconButton(
              tooltip: _obscure ? '显示' : '隐藏',
              icon: Icon(
                _obscure
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                size: 20,
              ),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        if (failure != null) _AssistantLine(keyCheckFailureMessage(failure)),
        _Choices([
          MoePrimaryButton(
            label: _checking ? '正在测试…' : '保存并测试',
            isLoading: _checking,
            enabled: !_checking,
            onPressed: _submit,
          ),
          if (failure == null)
            MoeSecondaryButton(
              label: '从剪贴板粘贴',
              icon: Icons.content_paste_rounded,
              enabled: !_checking,
              onPressed: _paste,
            ),
          if (failure == KeyCheckFailure.insufficientBalance)
            MoeSecondaryButton(
              label: '去充值',
              icon: Icons.open_in_new_rounded,
              onPressed: () => _openExternal(
                context,
                AssistantOnboardingView.deepSeekTopUpUrl,
              ),
            ),
          if (failure != null)
            MoeSecondaryButton(
              label: '换一家',
              onPressed: widget.controller.chooseOther,
            ),
        ]),
        _BackLink(
          onTap: () => widget.controller.goTo(
            widget.experienced
                ? OnboardingStep.chooseProvider
                : OnboardingStep.getKey,
          ),
        ),
      ],
    );
  }
}

/// Another provider: added with the regular add-provider sheet, then one of
/// its chat models is tested and becomes the default.
class _OtherProviderStep extends ConsumerStatefulWidget {
  const _OtherProviderStep({required this.controller});

  final AssistantOnboardingController controller;

  @override
  ConsumerState<_OtherProviderStep> createState() => _OtherProviderStepState();
}

class _OtherProviderStepState extends ConsumerState<_OtherProviderStep> {
  String? _checkingRef;
  KeyCheckFailure? _failure;

  Future<void> _use(String providerId, String modelId) async {
    setState(() {
      _checkingRef = '$providerId:$modelId';
      _failure = null;
    });
    final failure = await widget.controller.useProviderModel(
      providerId: providerId,
      modelId: modelId,
    );
    if (!mounted) return;
    setState(() {
      _checkingRef = null;
      _failure = failure;
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final candidates = [
      for (final provider in settings?.providers ?? const [])
        if (provider.capabilities.contains('chat') &&
            providerHasApiKey(provider) &&
            provider.visibleModels.isNotEmpty)
          provider,
    ];
    final failure = _failure;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _AssistantLine('点「添加渠道」，选接口格式，填上服务商给的地址和 Key，保存后回到这里，点一个模型我来测试。'),
        _Choices([
          MoePrimaryButton(
            label: '添加渠道',
            icon: Icons.add_rounded,
            enabled: _checkingRef == null,
            onPressed: () => showAddProviderSheet(context),
          ),
        ]),
        for (final provider in candidates) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 6),
            child: Text(
              provider.displayName ?? provider.id,
              style: TextStyle(
                fontSize: 14,
                color: context.moeColors.textSecondary,
              ),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final model in provider.visibleModels)
                MoeChoiceChip(
                  label: _checkingRef == '${provider.id}:$model'
                      ? '$model · 测试中…'
                      : model,
                  selected: _checkingRef == '${provider.id}:$model',
                  onTap: _checkingRef == null
                      ? () => _use(provider.id, model)
                      : null,
                ),
            ],
          ),
        ],
        if (failure != null) ...[
          const SizedBox(height: 10),
          _AssistantLine(keyCheckFailureMessage(failure)),
        ],
        _BackLink(
          onTap: () => widget.controller.goTo(OnboardingStep.chooseProvider),
        ),
      ],
    );
  }
}

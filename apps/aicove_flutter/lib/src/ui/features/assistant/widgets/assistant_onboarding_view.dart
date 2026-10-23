import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../features/assistant/application/assistant_onboarding_controller.dart';
import '../../../../features/assistant/domain/assistant_onboarding.dart';
import '../../../../features/chat/domain/message.dart';
import '../../../../features/chat/presentation/widgets/message_bubble.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../shared/widgets/index.dart';
import '../../../shared/widgets/ui_blocks/ui_block_options.dart';
import '../../../shared/widgets/ui_blocks/ui_block_primitives.dart';
import '../../../shared/widgets/ui_blocks/ui_block_style.dart';
import '../../settings/pages/add_provider_sheet.dart';

/// Scripted phase of the AIcove assistant (ADR0073): fixed lines and cards,
/// no model call. Shown in the assistant chat while no chat model is usable.
/// Lines reuse the chat's document-style message and the choices reuse the
/// interactive block look (ADR0091), so it reads like any role's chat.
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
    return _OnboardingSpeaker(
      displayName: displayName,
      avatarUrl: avatarUrl,
      child: ListView(
        key: ValueKey('assistant-onboarding-${state.step.name}'),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.fromLTRB(
          16,
          topPadding + 12,
          16,
          MediaQuery.paddingOf(context).bottom + 24,
        ),
        children: [step],
      ),
    );
  }
}

/// Who the scripted lines are spoken by, so every step draws them with the
/// same message bubble the chat list uses.
class _OnboardingSpeaker extends InheritedWidget {
  const _OnboardingSpeaker({
    required this.displayName,
    required this.avatarUrl,
    required super.child,
  });

  final String displayName;
  final String? avatarUrl;

  static _OnboardingSpeaker of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_OnboardingSpeaker>()!;

  @override
  bool updateShouldNotify(_OnboardingSpeaker oldWidget) =>
      displayName != oldWidget.displayName || avatarUrl != oldWidget.avatarUrl;
}

/// One scripted turn: the assistant's lines as a document-style chat message
/// (same widget as any role's reply), then the interactive block under it.
class _Turn extends StatelessWidget {
  const _Turn({required this.id, required this.lines, required this.children});

  final String id;
  final List<String> lines;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final speaker = _OnboardingSpeaker.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MessageBubble(
          isMe: false,
          message: Message.text(
            id: 'assistant-onboarding-$id',
            role: 'assistant',
            content: lines.join('\n\n'),
          ),
          avatarUrl: speaker.avatarUrl,
          displayName: speaker.displayName,
          documentStyle: true,
        ),
        // The block sits on a content surface so it follows the global
        // material and stays readable over the default wallpaper.
        if (children.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: MoeContentSurface(
              radius: 16,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < children.length; i++)
                    Padding(
                      padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
                      child: children[i],
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// A full-width action in the block; [primary] marks the suggested one.
class _Action extends StatelessWidget {
  const _Action({
    required this.label,
    required this.onTap,
    this.primary = false,
    this.icon,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final IconData? icon;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final style = UiBlockStyle.of(context);
    final color = primary ? style.accent : style.line;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: loading ? null : onTap,
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: primary ? color.withValues(alpha: 0.1) : null,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color, width: 0.8),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: style.small.copyWith(
                    color: onTap == null ? style.muted : null,
                    fontWeight: primary ? FontWeight.w600 : null,
                  ),
                ),
              ),
              if (loading)
                SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: style.accent,
                  ),
                )
              else
                Icon(
                  icon ?? Icons.chevron_right_rounded,
                  size: 16,
                  color: primary ? style.accent : style.muted,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A collapsed beginner question that unfolds in place.
class _Explain extends StatelessWidget {
  const _Explain({required this.question, required this.answer});

  final String question;
  final String answer;

  @override
  Widget build(BuildContext context) {
    final style = UiBlockStyle.of(context);
    return UiCollapse(
      title: question,
      initiallyOpen: false,
      style: style,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(answer, style: style.small.copyWith(color: style.muted)),
        ),
      ],
    );
  }
}

class _BackLink extends StatelessWidget {
  const _BackLink({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final style = UiBlockStyle.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          child: Text('返回上一步', style: style.caption),
        ),
      ),
    );
  }
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
  Widget build(BuildContext context) => _Turn(
    id: 'experience',
    lines: const [
      '你好呀，我是 AIcove酱～ 软件里的事我几乎都能直接帮你办：'
          '接模型、改设置、写角色卡、换头像和声音、导入预设，有什么问题直接找我就好。',
      '不过得先花一两分钟把 AI 接上，我才能真正动起来。',
      '你之前配置过 API、用过 AI Agent 吗？',
    ],
    children: [
      _Action(
        label: '完全没有，带我一步步来',
        primary: true,
        onTap: () => controller.chooseExperience(experienced: false),
      ),
      _Action(
        label: '配过 API，直接填 Key',
        onTap: () => controller.chooseExperience(experienced: true),
      ),
      _Action(label: '都会，跳过全部教程', onTap: controller.skipAll),
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
  Widget build(BuildContext context) => _Turn(
    id: 'chooseProvider',
    lines: experienced
        ? const ['用哪家模型服务？']
        : const [
            'AIcove 本身不带 AI，要接上一家「模型服务」才能聊天。'
                '可以这样理解：AIcove 是手机，模型服务是电话卡。',
            '推荐 DeepSeek：国内直接能用、按用量付费，聊天很便宜。',
          ],
    children: [
      if (!experienced) ...const [
        _Explain(
          question: 'API 是什么？',
          answer:
              'API 是程序之间互相「点单」的窗口。AIcove 把你说的话通过 API 发给模型服务，'
              '模型想好回复再传回来。你不用懂细节，接上就能用。',
        ),
        _Explain(
          question: 'Key 是什么？',
          answer:
              'Key 是模型服务发给你的「专属钥匙」，一串以 sk- 开头的字符。'
              '用量和费用都记在这把钥匙上，所以别发给别人。它只保存在你的设备上。',
        ),
      ],
      _Action(
        label: 'DeepSeek（推荐）',
        primary: true,
        onTap: controller.chooseRecommended,
      ),
      _Action(label: '其他家', onTap: controller.chooseOther),
      _BackLink(onTap: () => controller.goTo(OnboardingStep.experience)),
    ],
  );
}

class _GetKeyStep extends StatelessWidget {
  const _GetKeyStep({required this.controller});

  final AssistantOnboardingController controller;

  @override
  Widget build(BuildContext context) => _Turn(
    id: 'getKey',
    lines: const [
      '跟着这几步拿到 Key：',
      '1. 点下面的按钮打开 DeepSeek 开放平台，注册并登录。\n'
          '2. 在「充值」页充一点钱，按用量扣费，日常聊天很省。\n'
          '3. 打开「API Keys」，点「创建 API Key」，名字随便填。\n'
          '4. 复制生成的 Key（sk- 开头）。它只显示这一次，复制好再关掉窗口。',
    ],
    children: [
      _Action(
        label: '打开 DeepSeek 开放平台',
        primary: true,
        icon: Icons.open_in_new_rounded,
        onTap: () =>
            _openExternal(context, AssistantOnboardingView.deepSeekKeysUrl),
      ),
      _Action(
        label: '我复制好了',
        onTap: () => controller.goTo(OnboardingStep.pasteKey),
      ),
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
    final style = UiBlockStyle.of(context);
    return _Turn(
      id: 'pasteKey',
      lines: [
        widget.experienced
            ? '把 DeepSeek 的 API Key 粘贴到下面，我先试一下能不能用。'
            : '把刚复制的 Key 粘贴到下面，我先帮你试一下能不能用。',
      ],
      children: [
        TextField(
          key: const ValueKey('assistant-onboarding-key-field'),
          controller: _keyCtrl,
          obscureText: _obscure,
          enabled: !_checking,
          autocorrect: false,
          enableSuggestions: false,
          style: style.small,
          decoration: uiInputDecoration(style, hint: 'sk-...').copyWith(
            suffixIcon: IconButton(
              tooltip: _obscure ? '显示' : '隐藏',
              icon: Icon(
                _obscure
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                size: 18,
                color: style.muted,
              ),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
          onChanged: (_) {
            if (_failure != null) setState(() => _failure = null);
          },
          onSubmitted: (_) => _submit(),
        ),
        if (failure != null)
          UiCallout(
            title: '',
            text: keyCheckFailureMessage(failure),
            tone: 'warning',
            style: style,
          ),
        _Action(
          label: _checking ? '正在测试…' : '保存并测试',
          primary: true,
          icon: Icons.check_rounded,
          loading: _checking,
          onTap: _submit,
        ),
        if (failure == null)
          _Action(
            label: '从剪贴板粘贴',
            icon: Icons.content_paste_rounded,
            onTap: _checking ? null : _paste,
          ),
        if (failure == KeyCheckFailure.insufficientBalance)
          _Action(
            label: '去充值',
            icon: Icons.open_in_new_rounded,
            onTap: () => _openExternal(
              context,
              AssistantOnboardingView.deepSeekTopUpUrl,
            ),
          ),
        if (failure != null)
          _Action(label: '换一家', onTap: widget.controller.chooseOther),
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
    final style = UiBlockStyle.of(context);
    return _Turn(
      id: 'otherProvider',
      lines: const ['点「添加渠道」，选接口格式，填上服务商给的地址和 Key，保存后回到这里，点一个模型我来测试。'],
      children: [
        _Action(
          label: '添加渠道',
          primary: true,
          icon: Icons.add_rounded,
          onTap: _checkingRef == null
              ? () => showAddProviderSheet(context)
              : null,
        ),
        for (final provider in candidates) ...[
          Text(provider.displayName ?? provider.id, style: style.caption),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final model in provider.visibleModels)
                MoeChoiceChip(
                  size: MoeChoiceChipSize.sm,
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
        if (failure != null)
          UiCallout(
            title: '',
            text: keyCheckFailureMessage(failure),
            tone: 'warning',
            style: style,
          ),
        _BackLink(
          onTap: () => widget.controller.goTo(OnboardingStep.chooseProvider),
        ),
      ],
    );
  }
}

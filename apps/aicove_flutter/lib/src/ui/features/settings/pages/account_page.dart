import 'cloud_conflicts_page.dart';
import '../../../shared/animations/parallax_slide_page_route.dart';
import '../../../../features/sync/providers/cloud_sync_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/account/domain/account_port.dart';
import '../../../../features/account/providers/account_provider.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

class AccountPage extends ConsumerStatefulWidget {
  const AccountPage({super.key});

  @override
  ConsumerState<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends ConsumerState<AccountPage> {
  final _server = TextEditingController(text: defaultCloudServer);
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _seeded = false;

  @override
  void dispose() {
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final password = _password.text;
    _password.clear();
    await ref
        .read(accountProvider.notifier)
        .login(_server.text, _username.text, password);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(accountProvider);
    final connection = state.connection;
    if (!_seeded && connection != null) {
      _seeded = true;
      _server.text = connection.server;
      _username.text = connection.user.username;
    }
    final signedIn = connection?.hasSession ?? false;
    final colors = context.moeColors;
    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const MoeAppBar(title: '账号', showBackButton: true),
      body: Builder(
        builder: (context) => SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: moeUnderBarPadding(context, EdgeInsets.all(24)),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    signedIn ? '已登录' : '登录你的账号',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    connection == null
                        ? '首次登录会将这台设备的现有数据绑定到该账号，原有内容会保留。'
                        : '本地数据已绑定到此账号。退出登录会保留这些数据。',
                    style: TextStyle(color: colors.muted),
                  ),
                  if (connection != null) ...[
                    const SizedBox(height: 24),
                    MoeSettingsGroup(
                      margin: EdgeInsets.zero,
                      children: [
                        MoeSettingsRow(
                          icon: Icons.person_outline,
                          label: '用户名',
                          subtitle: connection.user.username,
                        ),
                        MoeSettingsRow(
                          icon: Icons.badge_outlined,
                          label: '账号 ID',
                          subtitle: connection.user.id.toString(),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 24),
                  MoeTextField(
                    key: const ValueKey('account-server'),
                    controller: _server,
                    label: '服务器地址',
                    keyboardType: TextInputType.url,
                    enabled: !state.busy && connection == null,
                  ),
                  if (!signedIn) ...[
                    const SizedBox(height: 16),
                    MoeTextField(
                      key: const ValueKey('account-username'),
                      controller: _username,
                      label: '用户名',
                      enabled: !state.busy,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 16),
                    MoeTextField(
                      key: const ValueKey('account-password'),
                      controller: _password,
                      label: '密码',
                      obscureText: false,
                      enabled: !state.busy,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _login(),
                    ),
                  ],
                  if (state.error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      state.error!,
                      style: TextStyle(color: colors.toastError),
                    ),
                  ],
                  const SizedBox(height: 24),
                  if (signedIn)
                    MoeSecondaryButton(
                      label: '退出登录',
                      enabled: !state.busy,
                      onPressed: () =>
                          ref.read(accountProvider.notifier).logout(),
                    )
                  else
                    MoePrimaryButton(
                      label: '登录',
                      isLoading: state.busy,
                      onPressed: _login,
                    ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: state.busy
                        ? null
                        : () => ref.read(accountProvider.notifier).refresh(),
                    child: const Text('刷新账号状态'),
                  ),
                  if (signedIn) ...[
                    const SizedBox(height: 24),
                    const _CloudSyncSettings(),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CloudSyncSettings extends ConsumerWidget {
  const _CloudSyncSettings();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(cloudSyncProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(state.message),
        if (state.totalMessages > 0)
          Text('本轮消息：${state.confirmedMessages}/${state.totalMessages} 条已确认'),
        if (state.uploadedFiles > 0)
          Text(
            '本轮已上传：${state.uploadedFiles} 个唯一文件，共 ${(state.uploadedBytes / (1024 * 1024)).toStringAsFixed(1)} MiB',
          ),
        const SizedBox(height: 8),
        const Text(
          '同步全部历史消息、界面与插件设置。仅超过 30 天的聊天图片可只传缩略图；近期聊天图片、头像、背景及插件用图均传原图。',
        ),
        if (state.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(state.error!),
          ),
        const SizedBox(height: 12),
        MoePrimaryButton(
          label: state.enabled ? '立即同步' : '开启云同步',
          isLoading: state.busy,
          onPressed: () => state.enabled
              ? ref.read(cloudSyncProvider.notifier).synchronize()
              : ref.read(cloudSyncProvider.notifier).enable(),
        ),
        if (state.enabled)
          TextButton(
            onPressed: state.busy
                ? null
                : () => Navigator.of(context).push(
                    ParallaxSlidePageRoute<void>(
                      page: const CloudConflictsPage(),
                    ),
                  ),
            child: const Text('处理同时修改'),
          ),
        if (state.enabled)
          TextButton(
            onPressed: () => ref.read(cloudSyncProvider.notifier).pause(),
            child: const Text('暂停自动同步'),
          ),
      ],
    );
  }
}

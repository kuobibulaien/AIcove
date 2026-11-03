import 'cloud_conflicts_page.dart';
import 'lan_sync_page.dart';
import '../../../shared/animations/parallax_slide_page_route.dart';
import '../../../../features/sync/providers/cloud_sync_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/account/domain/account_port.dart';
import '../../../../features/account/providers/account_provider.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

const cloudSyncDeployCommands = '''cd cloud_backend
python3 -m sync_v3 init-config
docker compose up -d
docker compose exec sync-v3 python -m sync_v3 create-user --username myname''';

const cloudSyncAiDeployPrompt = '''我想在自己的服务器上部署 AIcove 的自建云同步服务（仓库里的 cloud_backend 目录），请一步步带我完成部署：

1. 环境要求：
   - 一台有公网 IP 和域名的服务器（已安装 Docker 与 Docker Compose，或 Python 3.11+）
   - AIcove 客户端要求正式环境使用 HTTPS 地址连接

2. 部署步骤（在项目的 cloud_backend 目录下执行）：
   - 生成配置与密钥：运行 `python3 -m sync_v3 init-config`（若本机没装 Python，可用 `docker compose run --rm sync-v3 python -m sync_v3 init-config`），会自动生成带随机密钥的 `.env` 文件
   - 启动服务：运行 `docker compose up -d`（默认监听 `127.0.0.1:8000`，数据保存在 `./data` 目录）
   - 创建登录账号：运行 `docker compose exec sync-v3 python -m sync_v3 create-user --username <我的用户名>` 并按提示输入密码
   - 检查运行状态：访问 `http://127.0.0.1:8000/api/v1/health` 确认返回正常

3. 配置 HTTPS 反向代理：
   - 请根据我服务器现有的工具（Caddy / Nginx / 宝塔 / 1Panel），帮我把 HTTPS 域名反向代理到 `http://127.0.0.1:8000`
   - 完成后告诉我最终填进 AIcove「服务器地址」里的完整 `https://...` 地址。''';

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
  bool _showDeployGuide = false;

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

  Future<void> _copyText(String text, String toastMessage) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    MoeToast.success(context, toastMessage);
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
      appBar: const MoeAppBar(title: '云同步', showBackButton: true),
      body: Builder(
        builder: (context) => SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: moeUnderBarPadding(
            context,
            const EdgeInsets.fromLTRB(24, 16, 24, 24),
          ),
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
                  const SizedBox(height: 8),
                  Text(
                    connection == null
                        ? '云同步默认关闭，日常推荐优先使用「局域网同步」。如已自备服务器，首次登录会将本机数据绑定到该账号。'
                        : '本地数据已绑定到此账号。退出登录会保留这些数据。',
                    style: TextStyle(color: colors.muted),
                  ),
                  if (connection != null) ...[
                    const SizedBox(height: 16),
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
                          showDivider: false,
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  MoeTextField(
                    key: const ValueKey('account-server'),
                    controller: _server,
                    label: '服务器地址',
                    hint: '例如 https://sync.example.com',
                    keyboardType: TextInputType.url,
                    enabled: !state.busy && connection == null,
                  ),
                  if (!signedIn) ...[
                    const SizedBox(height: 12),
                    MoeTextField(
                      key: const ValueKey('account-username'),
                      controller: _username,
                      label: '用户名',
                      enabled: !state.busy,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 12),
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
                    const SizedBox(height: 12),
                    Text(
                      state.error!,
                      style: TextStyle(color: colors.toastError),
                    ),
                  ],
                  const SizedBox(height: 16),
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
                  const SizedBox(height: 10),
                  MoeSecondaryButton(
                    label: '刷新账号状态',
                    icon: Icons.refresh,
                    onPressed: state.busy
                        ? null
                        : () => ref.read(accountProvider.notifier).refresh(),
                  ),
                  if (signedIn) ...[
                    const SizedBox(height: 20),
                    const _CloudSyncSettings(),
                  ],
                  const SizedBox(height: 16),
                  MoeSettingsGroup(
                    margin: EdgeInsets.zero,
                    children: [
                      MoeSettingsRow(
                        icon: Icons.devices_outlined,
                        label: '去用局域网同步（首选）',
                        subtitle: '同一 Wi-Fi 或热点扫码直连，无需服务器',
                        trailingType: MoeSettingsRowTrailing.chevron,
                        onTap: () => Navigator.of(context).push(
                          ParallaxSlidePageRoute<void>(
                            page: const LanSyncPage(),
                          ),
                        ),
                      ),
                      MoeSettingsRow(
                        icon: Icons.auto_awesome_outlined,
                        label: '自建服务器与 AI 辅助部署',
                        subtitle: _showDeployGuide
                            ? '收起自建步骤与一键复制命令'
                            : '查看三步搭建指南，或复制提示词让 AI 帮你部署',
                        trailingType: MoeSettingsRowTrailing.chevron,
                        showDivider: _showDeployGuide,
                        onTap: () => setState(
                          () => _showDeployGuide = !_showDeployGuide,
                        ),
                      ),
                      if (_showDeployGuide) ...[
                        const MoeSettingsRow(
                          icon: Icons.dns_outlined,
                          label: '1. 准备一台你自己的服务器',
                          subtitle:
                              '需带公网 IP 与 HTTPS 域名并安装 Docker，服务端代码在仓库 cloud_backend 目录',
                          trailingType: MoeSettingsRowTrailing.none,
                        ),
                        const MoeSettingsRow(
                          icon: Icons.terminal_outlined,
                          label: '2. 生成密钥并启动服务',
                          subtitle:
                              '运行 init-config 生成配置，再执行 docker compose up -d 启动并配置 HTTPS 反向代理',
                          trailingType: MoeSettingsRowTrailing.none,
                        ),
                        const MoeSettingsRow(
                          icon: Icons.person_add_alt_1_outlined,
                          label: '3. 创建你的专属账号',
                          subtitle:
                              '运行 create-user 设置用户名和密码，再把 HTTPS 地址填到上方登录',
                          trailingType: MoeSettingsRowTrailing.none,
                          showDivider: false,
                        ),
                      ],
                    ],
                  ),
                  if (_showDeployGuide) ...[
                    const SizedBox(height: 12),
                    MoeSecondaryButton(
                      label: '复制 AI 辅助部署提示词',
                      icon: Icons.auto_awesome_outlined,
                      onPressed: () => _copyText(
                        cloudSyncAiDeployPrompt,
                        '已复制提示词，可直接发给 AI 一步步带你部署',
                      ),
                    ),
                    const SizedBox(height: 10),
                    MoeSecondaryButton(
                      label: '复制终端部署命令',
                      icon: Icons.copy_outlined,
                      onPressed: () => _copyText(
                        cloudSyncDeployCommands,
                        '已复制终端部署命令',
                      ),
                    ),
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
          Text('已上传 ${state.uploadedFiles} 个文件'),
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
        if (state.enabled) ...[
          const SizedBox(height: 12),
          MoeSecondaryButton(
            label: '处理同时修改',
            enabled: !state.busy,
            onPressed: () => Navigator.of(context).push(
              ParallaxSlidePageRoute<void>(page: const CloudConflictsPage()),
            ),
          ),
          const SizedBox(height: 12),
          MoeSecondaryButton(
            label: '暂停自动同步',
            onPressed: () => ref.read(cloudSyncProvider.notifier).pause(),
          ),
        ],
      ],
    );
  }
}

import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import '../../../../features/sync/domain/lan_contract.dart';
import '../../../../features/sync/domain/lan_sync_port.dart';
import '../../../../features/sync/providers/lan_sync_provider.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

class LanSyncPage extends ConsumerStatefulWidget {
  const LanSyncPage({super.key});
  @override
  ConsumerState<LanSyncPage> createState() => _LanSyncPageState();
}

class _LanSyncPageState extends ConsumerState<LanSyncPage> {
  final _name = TextEditingController(), _code = TextEditingController();
  final _saveName = MoeAutoSaveController();
  bool _seeded = false, _action = false;
  @override
  void dispose() {
    _saveName.dispose();
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function(LanSyncPort) operation) async {
    if (_action) return;
    setState(() => _action = true);
    try {
      final port = await ref.read(lanSyncPortProvider.future);
      if (!await _saveName.flush()) return;
      await operation(port);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e is LanSyncFailure ? e.message : '操作未完成，请稍后重试'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _action = false);
    }
  }

  Future<void> _image(bool camera) => _run((port) async {
    Uint8List? bytes;
    if (camera) {
      final photo = await ImagePicker().pickImage(
        source: ImageSource.camera,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 95,
      );
      bytes = await photo?.readAsBytes();
    } else {
      final files = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
      bytes = files?.files.single.bytes;
    }
    if (bytes == null) return;
    final code = await port.decodeQr(bytes);
    if (mounted) _code.text = code;
    await port.pair(code);
  });
  Future<void> _forget(LanPeerView peer) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('取消与${peer.name}的配对？'),
        content: const Text('本机历史保留；对方将无法继续读取或同步本机数据。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保留'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('取消配对'),
          ),
        ],
      ),
    );
    if (approved == true) await _run((port) => port.forget(peer.id));
  }

  Future<void> _conflict(List<LanRevision> versions) async {
    final selected = await showDialog<LanRevision>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择保留的版本'),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('两端同时修改了这份内容。选择后，两端会采用这一份；其它版本仍保留在同步记录中。'),
                const SizedBox(height: 12),
                for (final version in versions)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            _versionSource(version, versions),
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _description(version),
                            maxLines: 8,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: () => Navigator.pop(context, version),
                            child: const Text('采用这一份'),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('稍后处理'),
          ),
        ],
      ),
    );
    if (selected != null) {
      await _run(
        (port) => port.resolve(selected, versions.map((v) => v.hash).toList()),
      );
    }
  }

  String _description(LanRevision version) {
    if (version.deleted) return '删除版本';
    final row = version.payload['row'];
    if (row is Map) {
      if (version.kind == 'messages') {
        return row['content']?.toString() ?? '聊天内容';
      }
      final name = row['display_name'] ?? row['title'] ?? row['name'] ?? '设置';
      final wallpaper = row['chat_background_image'];
      return '$name${wallpaper is String && wallpaper.isNotEmpty ? '\n已设置壁纸' : ''}';
    }
    if (version.kind == 'plugin_presets') {
      final text = version.payload['json_value']?.toString() ?? '预设文件';
      return text.length > 600 ? '${text.substring(0, 600)}…' : text;
    }
    return '模型或插件设置：${version.id}';
  }

  String _versionSource(LanRevision version, List<LanRevision> versions) {
    final state = ref.read(lanSyncStateProvider).valueOrNull;
    final others = versions.where((v) => v.hash != version.hash);
    final authors = version.vector.entries.where(
      (entry) =>
          others.every((other) => (other.vector[entry.key] ?? 0) < entry.value),
    );
    final names = authors
        .map(
          (entry) => entry.key == state?.deviceId
              ? state!.name
              : state?.peers
                        .where((p) => p.id == entry.key)
                        .firstOrNull
                        ?.name ??
                    '另一台设备',
        )
        .toSet();
    return names.isEmpty
        ? '原有版本'
        : names.length == 1
        ? '来自${names.single}'
        : '多台设备合并的版本';
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(lanSyncStateProvider);
    final state = async.valueOrNull;
    if (state != null && !_seeded) {
      _seeded = true;
      _name.text = state.name;
      _saveName.configure(
        fields: [_name],
        snapshot: () => _name.text,
        save: () async {
          final port = await ref.read(lanSyncPortProvider.future);
          await port.setName(_name.text);
          if (port.state.error != null) throw LanSyncFailure(port.state.error!);
        },
      );
    }
    final colors = context.moeColors;
    return MoeAutoSaveScope(
      controller: _saveName,
      child: MoePageScaffold(
        extendBodyBehindAppBar: true,
        appBar: const MoeAppBar(title: '局域网同步', showBackButton: true),
        body: Builder(
          builder: (context) => SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: moeUnderBarPadding(
              context,
              const EdgeInsets.fromLTRB(16, 8, 16, 32),
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('设备之间直接同步，不需要云账号。两端连接同一 Wi-Fi 或热点，并保持应用打开。'),
                    const SizedBox(height: 16),
                    if (state == null) ...[
                      if (async.hasError) const Text('局域网同步初始化失败，请重试'),
                      if (async.isLoading)
                        const Center(child: CircularProgressIndicator()),
                      TextButton(
                        onPressed: () => ref.invalidate(lanSyncPortProvider),
                        child: const Text('重新加载'),
                      ),
                    ] else ...[
                      MoeSettingsGroup(
                        margin: EdgeInsets.zero,
                        children: [
                          MoeSettingsRow(
                            label: '开启局域网同步',
                            subtitle: '关闭后停止连接，本机数据保留',
                            trailingType: MoeSettingsRowTrailing.switchControl,
                            switchValue: state.enabled,
                            onSwitchChanged: _action
                                ? null
                                : (v) => _run((port) => port.setEnabled(v)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      MoeTextField(
                        controller: _name,
                        label: '本机名称',
                        enabled: !_action,
                        onSubmitted: (_) => _saveName.flush(),
                      ),
                      if (state.error != null)
                        Text(
                          state.error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      if (state.notice != null)
                        Text(
                          state.notice!,
                          style: TextStyle(color: colors.muted),
                        ),
                      if (state.enabled) ...[
                        const SizedBox(height: 20),
                        Text(
                          '添加另一台设备',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 10),
                        MoePrimaryButton(
                          label: '显示配对二维码',
                          onPressed: _action
                              ? null
                              : () => _run((port) => port.invite()),
                        ),
                        if (state.invitation != null) ...[
                          const SizedBox(height: 12),
                          Center(
                            child: Container(
                              color: Colors.white,
                              padding: const EdgeInsets.all(12),
                              width: 244,
                              child: PrettyQrView.data(data: state.invitation!),
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            '请用另一台设备拍摄或导入二维码；配对码十分钟后失效。',
                            textAlign: TextAlign.center,
                          ),
                          TextButton(
                            onPressed: () => Clipboard.setData(
                              ClipboardData(text: state.invitation!),
                            ),
                            child: const Text('复制配对码'),
                          ),
                        ],
                        const SizedBox(height: 12),
                        MoeTextField(
                          controller: _code,
                          label: '粘贴另一台设备的配对码',
                          maxLines: 3,
                          enabled: !_action,
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            TextButton(
                              onPressed: _action
                                  ? null
                                  : () => _run((port) async {
                                      await port.pair(_code.text);
                                      _code.clear();
                                    }),
                              child: const Text('连接设备'),
                            ),
                            if (Platform.isAndroid || Platform.isIOS)
                              TextButton(
                                onPressed: _action ? null : () => _image(true),
                                child: const Text('拍摄二维码'),
                              ),
                            TextButton(
                              onPressed: _action ? null : () => _image(false),
                              child: const Text('导入二维码'),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 24),
                      Text(
                        '已配对设备',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      if (state.peers.isEmpty)
                        const Text('还没有配对设备，现有历史会在首次连接时合并。'),
                      for (final peer in state.peers)
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  peer.name,
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  peer.pending
                                      ? (peer.incoming
                                            ? '请求与你配对，请确认设备名称'
                                            : '等待对方确认')
                                      : peer.error ??
                                            (peer.online
                                                ? '已连接${peer.lastSync == null ? '' : ' · 最近同步 ${_time(peer.lastSync!)}'}'
                                                : '等待设备上线'),
                                ),
                                Wrap(
                                  spacing: 8,
                                  children: [
                                    if (peer.pending && peer.incoming)
                                      TextButton(
                                        onPressed: _action || !state.enabled
                                            ? null
                                            : () => _run(
                                                (port) => port.approve(peer.id),
                                              ),
                                        child: const Text('确认配对'),
                                      ),
                                    TextButton(
                                      onPressed: _action
                                          ? null
                                          : () => _forget(peer),
                                      child: const Text('取消配对'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (state.enabled && state.peers.isNotEmpty)
                        MoePrimaryButton(
                          label: state.busy ? '正在同步…' : '立即同步',
                          onPressed: _action || state.busy
                              ? null
                              : () => _run((port) => port.synchronize()),
                        ),
                      if (state.pendingFiles > 0)
                        Text('${state.pendingFiles} 份附件等待传输'),
                      if (state.unavailableFiles > 0)
                        Text('${state.unavailableFiles} 份历史附件的原文件暂不可用'),
                      if (state.conflicts.isNotEmpty) ...[
                        const SizedBox(height: 20),
                        Text(
                          '需要选择的内容',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        for (final conflict in state.conflicts)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              conflict.first.kind == 'messages'
                                  ? '聊天同时被修改'
                                  : '设置或预设同时被修改',
                            ),
                            subtitle: Text(
                              _description(conflict.first),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: _action ? null : () => _conflict(conflict),
                          ),
                      ],
                      const SizedBox(height: 20),
                      Text(
                        '“通用”设置只保存在本机。角色、聊天、模型、插件和预设会参与同步。',
                        style: TextStyle(color: colors.muted),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _time(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
}

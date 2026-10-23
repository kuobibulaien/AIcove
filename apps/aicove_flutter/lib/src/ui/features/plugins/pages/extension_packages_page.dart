import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/platform_utils.dart';
import '../../../../features/plugins/packages/aicove_package.dart';
import '../../../../features/plugins/packages/package_plugin.dart';
import '../../../../features/plugins/packages/package_providers.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

/// 扩展包列表：本地导入的技能包与 JS 脚本插件（ADR0103），角色需单独开启。
class ExtensionPackagesPage extends ConsumerStatefulWidget {
  const ExtensionPackagesPage({super.key});

  static const title = '扩展包';

  @override
  ConsumerState<ExtensionPackagesPage> createState() =>
      _ExtensionPackagesPageState();
}

class _ExtensionPackagesPageState extends ConsumerState<ExtensionPackagesPage> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final packages = ref.watch(aicovePackagesProvider);

    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(
        title: ExtensionPackagesPage.title,
        showBackButton: true,
      ),
      body: MoeSettingsContent(
        child: Builder(
          builder: (context) => ListView(
            padding: moeUnderBarPadding(
              context,
              MoeSettingsLayout.verticalListPadding,
            ),
            children: [
              MoeSettingsGroup(
                title: '已安装',
                children: [
                  for (final package in packages)
                    MoeSettingsRow(
                      key: ValueKey('extension-package-${package.id}'),
                      icon: Icons.extension_outlined,
                      label: package.name,
                      subtitle: package.description.trim().isEmpty
                          ? null
                          : package.description.trim(),
                      // 行本身不跳转，只显示摘要文字，不带箭头。
                      trailingType: MoeSettingsRowTrailing.custom,
                      trailing: Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: Text(
                          _summary(package),
                          style: TextStyle(fontSize: 14, color: colors.muted),
                        ),
                      ),
                      onLongPress: () => _delete(package),
                    ),
                  if (PlatformUtils.isDesktop)
                    _importRow(
                      colors,
                      key: 'extension-import-folder',
                      icon: Icons.create_new_folder_outlined,
                      label: '导入文件夹',
                      onTap: _importFolder,
                    ),
                  _importRow(
                    colors,
                    key: 'extension-import-zip',
                    icon: Icons.add,
                    label: '导入 zip',
                    onTap: _importZip,
                    last: true,
                  ),
                ],
              ),
              const SizedBox(height: MoeSettingsLayout.sectionGap),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  '支持带 SKILL.md 的技能包和 AIcove 扩展包。'
                  '导入后需在角色的「管理插件」里单独开启；长按可删除。',
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _importRow(
    MoeColors colors, {
    required String key,
    required IconData icon,
    required String label,
    required Future<void> Function() onTap,
    bool last = false,
  }) => MoeSettingsRow(
    key: ValueKey(key),
    icon: icon,
    iconColor: colors.primary,
    label: label,
    labelColor: _busy ? colors.muted : colors.primary,
    trailingType: MoeSettingsRowTrailing.none,
    showDivider: !last,
    onTap: _busy ? null : onTap,
  );

  static String _summary(AicovePackage package) {
    final parts = [
      if (package.skills.isNotEmpty) '${package.skills.length} 个技能',
      if (package.scriptMain != null) '脚本',
    ];
    return parts.join(' · ');
  }

  Future<void> _importFolder() async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null) return;
    await _install(
      () => ref
          .read(aicovePackagesProvider.notifier)
          .importDirectory(Directory(path)),
    );
  }

  Future<void> _importZip() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['zip'],
      withData: true,
    );
    final file = picked?.files.single;
    if (file == null) return;
    final bytes = file.bytes ?? await File(file.path!).readAsBytes();
    await _install(
      () => ref.read(aicovePackagesProvider.notifier).importZip(bytes),
    );
  }

  Future<void> _install(Future<AicovePackage> Function() install) async {
    setState(() => _busy = true);
    try {
      final package = await install();
      // 文件解析成功不代表脚本能注册，先试加载一次再告诉用户。
      final plugin = PackagePlugin(package);
      await plugin.prepare();
      if (!mounted) return;
      final error = plugin.script.loadError;
      if (error != null) {
        MoeToast.error(context, '已导入「${package.name}」，但脚本加载失败：$error');
      } else {
        MoeToast.success(context, '已导入「${package.name}」');
      }
    } on PackageFormatException catch (e) {
      if (mounted) MoeToast.error(context, '导入失败：${e.message}');
    } catch (e) {
      if (mounted) MoeToast.error(context, '导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(AicovePackage package) async {
    final confirmed = await showMeoTalkConfirm(
      context: context,
      title: '删除扩展包',
      message: '删除「${package.name}」后，所有角色都不能再使用它。',
      confirmText: '删除',
      isDanger: true,
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(aicovePackagesProvider.notifier).delete(package.id);
    } catch (e) {
      if (mounted) MoeToast.error(context, '删除失败：$e');
    }
  }
}

/// ProviderDialogs - 渠道相关对话框
/// 
/// 从 model_list_page.dart 提取，提供渠道操作的对话框函数。
/// 
/// 更新记录：
/// - 2025-12-31: 从 model_list_page.dart 提取
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/settings/app_settings.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/index.dart';
import 'provider_section_card.dart';

/// 显示编辑渠道弹窗
Future<void> showEditProviderDialog(
  BuildContext context,
  WidgetRef ref,
  ProviderAuth provider,
) async {
  final nameCtrl = TextEditingController(text: provider.displayName ?? '');
  final baseCtrl = TextEditingController(text: provider.apiBaseUrl);
  final keyCtrl = TextEditingController(
    text: provider.apiKeys.isNotEmpty ? provider.apiKeys.first : '',
  );
  final formKey = GlobalKey<FormState>();
  final title = providerTitle(provider);

  final confirmed = await showMoeBottomSheet<bool>(
    context: context,
    title: '编辑渠道：$title',
    showCloseButton: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Form(
        key: formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: '显示名称',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: baseCtrl,
                decoration: const InputDecoration(
                  labelText: 'API Base URL',
                  border: OutlineInputBorder(),
                ),
                validator: (value) =>
                    (value == null || value.trim().isEmpty) ? '请输入 API Base URL' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: keyCtrl,
                decoration: const InputDecoration(
                  labelText: 'API Key',
                  hintText: '留空则不修改',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  MoeSecondaryButton(
                    label: '取消',
                    onPressed: () => Navigator.pop(context, false),
                  ),
                  const SizedBox(width: 12),
                  MoePrimaryButton(
                    label: '保存',
                    onPressed: () {
                      if (formKey.currentState?.validate() ?? false) {
                        Navigator.pop(context, true);
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );

  if (confirmed == true) {
    final newKey = keyCtrl.text.trim();
    await ref.read(appSettingsProvider.notifier).editProvider(
          providerId: provider.id,
          displayName: nameCtrl.text.trim().isEmpty ? null : nameCtrl.text.trim(),
          apiBaseUrl: baseCtrl.text.trim(),
          apiKeys: newKey.isNotEmpty ? [newKey] : null,
        );
    if (!context.mounted) return;
    MoeToast.success(context, '渠道已更新');
  }
}

/// 测试渠道连接
Future<void> testConnection(
  BuildContext context,
  WidgetRef ref,
  ProviderAuth provider,
) async {
  final colors = context.moeColors;

  if (provider.apiKeys.isEmpty) {
    MoeToast.warning(context, '该渠道未配置 API Key，无法测试');
    return;
  }

  // 显示加载状态
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => Center(
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MoeLoadingIndicator(size: MoeLoadingSize.lg),
            SizedBox(height: 16),
            Text('正在测试连接...'),
          ],
        ),
      ),
    ),
  );

  try {
    final models = await ref.read(appSettingsProvider.notifier).previewProviderModels(
          providerId: provider.id,
          apiKey: provider.apiKeys.first,
          apiBaseUrl: provider.apiBaseUrl,
        );

    if (!context.mounted) return;
    Navigator.pop(context); // 关闭加载对话框

    // 显示成功结果（使用底部弹窗）
    showMoeBottomSheet(
      context: context,
      title: '连接成功',
      builder: (context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.check_circle,
              color: Colors.green,
              size: 48,
            ),
            const SizedBox(height: 16),
            Text(
              '成功获取到 ${models.length} 个模型',
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: MoePrimaryButton(
                label: '确定',
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  } catch (e) {
    if (!context.mounted) return;
    Navigator.pop(context); // 关闭加载对话框

    // 显示错误结果
    showMoeBottomSheet(
      context: context,
      title: '连接失败',
      builder: (context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error,
              color: Colors.red,
              size: 48,
            ),
            const SizedBox(height: 16),
            Text(
              '错误信息：\n$e',
              style: TextStyle(
                fontSize: 14,
                color: colors.muted,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: MoePrimaryButton(
                label: '确定',
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

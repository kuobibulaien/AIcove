import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/plugins/plugin_providers.dart';
import '../../../../features/plugins/web_search/web_search_adapter.dart';
import '../../../../features/plugins/web_search/web_search_config.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

/// 单个搜索供应商的设置：名称、密钥、接口地址、启用与测试。
class WebSearchProviderDetailPage extends ConsumerStatefulWidget {
  const WebSearchProviderDetailPage({super.key, required this.providerId});

  final String providerId;

  @override
  ConsumerState<WebSearchProviderDetailPage> createState() =>
      _WebSearchProviderDetailPageState();
}

class _WebSearchProviderDetailPageState
    extends ConsumerState<WebSearchProviderDetailPage> {
  bool _testing = false;

  WebSearchProviderEntry? _current() => ref
      .read(webSearchPluginConfigProvider)
      .providers
      .where((p) => p.id == widget.providerId)
      .firstOrNull;

  Future<void> _save(
    WebSearchProviderEntry Function(WebSearchProviderEntry entry) change,
  ) async {
    final entry = _current();
    if (entry == null) return;
    await ref
        .read(webSearchPluginConfigProvider.notifier)
        .saveProvider(change(entry));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final entry = ref
        .watch(webSearchPluginConfigProvider)
        .providers
        .where((p) => p.id == widget.providerId)
        .firstOrNull;

    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: colors.surface,
      appBar: MoeAppBar(
        title: entry?.displayName ?? '搜索供应商',
        showBackButton: true,
      ),
      body: MoeSettingsContent(
        child: entry == null
            ? const SizedBox.shrink()
            : Builder(
                builder: (context) => ListView(
                  padding: moeUnderBarPadding(
                    context,
                    MoeSettingsLayout.verticalListPadding,
                  ),
                  children: [
                    MoeSettingsGroup(
                      children: [
                        MoeSettingsRow(
                          key: const ValueKey('web-search-provider-enabled'),
                          label: '启用',
                          trailingType: MoeSettingsRowTrailing.switchControl,
                          switchValue: entry.enabled,
                          onSwitchChanged: (value) =>
                              _guard(_save((e) => e.copyWith(enabled: value))),
                        ),
                        MoeSettingsRow(
                          label: '类型',
                          trailingType: MoeSettingsRowTrailing.custom,
                          trailing: Text(
                            entry.type.label,
                            style: TextStyle(fontSize: 14, color: colors.muted),
                          ),
                        ),
                        MoeSettingsRow(
                          label: '名称',
                          trailingType: MoeSettingsRowTrailing.text,
                          detailText: entry.displayName,
                          showDivider: false,
                          onTap: () => _editText(
                            title: '名称',
                            initialValue: entry.name,
                            hint: entry.type.label,
                            apply: (e, value) => e.copyWith(name: value.trim()),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: MoeSettingsLayout.sectionGap),
                    MoeSettingsGroup(
                      title: '连接',
                      children: [
                        MoeSettingsRow(
                          key: const ValueKey('web-search-provider-key'),
                          label: entry.type.requiresApiKey
                              ? 'API 密钥'
                              : 'API 密钥（可选）',
                          subtitle: entry.type.keyHint,
                          trailingType: MoeSettingsRowTrailing.text,
                          detailText: entry.apiKey.trim().isEmpty
                              ? '未填写'
                              : _maskKey(entry.apiKey),
                          onTap: () => _editText(
                            title: 'API 密钥',
                            initialValue: entry.apiKey,
                            hint: '粘贴 ${entry.type.label} API Key',
                            obscureText: true,
                            apply: (e, value) =>
                                e.copyWith(apiKey: value.trim()),
                          ),
                        ),
                        MoeSettingsRow(
                          label: '接口地址',
                          subtitle: entry.type.defaultBaseUrl.isEmpty
                              ? '必填，填写自建实例地址'
                              : '留空使用官方地址，也可填兼容的代理',
                          trailingType: MoeSettingsRowTrailing.text,
                          detailText: entry.baseUrl.trim().isNotEmpty
                              ? entry.baseUrl.trim()
                              : entry.type.defaultBaseUrl.isEmpty
                              ? '未填写'
                              : '默认',
                          showDivider: false,
                          onTap: () => _editText(
                            title: '接口地址',
                            initialValue: entry.baseUrl,
                            hint: entry.type.defaultBaseUrl.isEmpty
                                ? 'https://searx.example.com'
                                : entry.type.defaultBaseUrl,
                            keyboardType: TextInputType.url,
                            apply: (e, value) {
                              final trimmed = value.trim();
                              if (trimmed.isNotEmpty && !_isHttpUrl(trimmed)) {
                                throw const FormatException('请输入 http(s) 地址');
                              }
                              return e.copyWith(baseUrl: trimmed);
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: MoeSettingsLayout.sectionGap),
                    MoeSettingsGroup(
                      children: [
                        MoeSettingsRow(
                          key: const ValueKey('web-search-provider-test'),
                          label: _testing ? '正在测试…' : '测试搜索',
                          subtitle: '用这家供应商搜索一次，确认配置可用',
                          enabled: entry.isReady && !_testing,
                          onTap: () => _test(entry),
                        ),
                        MoeSettingsRow(
                          key: const ValueKey('web-search-provider-delete'),
                          label: '删除供应商',
                          labelColor: Theme.of(context).colorScheme.error,
                          trailingType: MoeSettingsRowTrailing.none,
                          showDivider: false,
                          onTap: () => _delete(entry),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  static bool _isHttpUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  static String _maskKey(String key) {
    final trimmed = key.trim();
    if (trimmed.length <= 8) return '已填写';
    return '${trimmed.substring(0, 4)}…${trimmed.substring(trimmed.length - 4)}';
  }

  Future<void> _guard(Future<void> task) async {
    try {
      await task;
    } catch (e) {
      if (mounted) MoeToast.error(context, '$e');
    }
  }

  Future<void> _editText({
    required String title,
    required String initialValue,
    required WebSearchProviderEntry Function(
      WebSearchProviderEntry entry,
      String value,
    )
    apply,
    String? hint,
    TextInputType? keyboardType,
    bool obscureText = false,
  }) {
    return showMoeAutoSaveTextEditor(
      context: context,
      title: title,
      initialValue: initialValue,
      hint: hint,
      keyboardType: keyboardType,
      obscureText: obscureText,
      onSave: (value) => _save((entry) => apply(entry, value)),
    );
  }

  Future<void> _test(WebSearchProviderEntry entry) async {
    setState(() => _testing = true);
    try {
      final results = await createWebSearchAdapter(entry).search(
        'latest news today',
        numResults: 1,
        maxCharacters: WebSearchConfig.minCharacters,
      );
      if (!mounted) return;
      MoeToast.success(context, '搜索可用，返回 ${results.length} 条结果');
    } catch (e) {
      if (!mounted) return;
      MoeToast.error(context, '$e');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _delete(WebSearchProviderEntry entry) async {
    final confirm = await showMeoTalkDialog(
      context: context,
      title: '删除供应商',
      content: Text('确定删除「${entry.displayName}」吗？密钥等配置会一起删除。'),
      confirmText: '删除',
      cancelText: '取消',
      isDanger: true,
    );
    if (confirm != true || !mounted) return;
    try {
      await ref
          .read(webSearchPluginConfigProvider.notifier)
          .removeProvider(entry.id);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) MoeToast.error(context, '$e');
    }
  }
}

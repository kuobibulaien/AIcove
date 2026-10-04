import 'package:flutter/material.dart';

import '../../../../core/api/providers/provider_extra_body.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

/// 编辑渠道额外请求参数；返回 null 表示取消，空表表示清空。
Future<Map<String, dynamic>?> showProviderExtraBodyEditor(
  BuildContext context,
  Map<String, dynamic> customConfig,
) => showDialog<Map<String, dynamic>>(
  context: context,
  builder: (context) => Dialog(
    backgroundColor: Colors.transparent,
    insetPadding: const EdgeInsets.all(16),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: ProviderExtraBodyEditor(customConfig: customConfig),
    ),
  ),
);

class ProviderExtraBodyEditor extends StatefulWidget {
  const ProviderExtraBodyEditor({super.key, required this.customConfig});

  final Map<String, dynamic> customConfig;

  @override
  State<ProviderExtraBodyEditor> createState() =>
      _ProviderExtraBodyEditorState();
}

class _ProviderExtraBodyEditorState extends State<ProviderExtraBodyEditor> {
  late final TextEditingController _json = TextEditingController(
    text: formatProviderExtraBody(widget.customConfig),
  );
  String? _error;

  @override
  void dispose() {
    _json.dispose();
    super.dispose();
  }

  void _save() {
    try {
      Navigator.of(context).pop(parseProviderExtraBody(_json.text));
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return MoeFloatingSurface(
      radius: 20,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '额外请求参数',
                    style: TextStyle(fontSize: 18, color: colors.text),
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '填写 JSON 对象，每次聊天请求都会合并到请求体顶层，同名字段以这里为准。留空即清除。',
                    style: TextStyle(fontSize: 13, color: colors.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('provider-extra-body-json'),
                    controller: _json,
                    minLines: 4,
                    maxLines: 10,
                    style: const TextStyle(fontFamily: 'monospace'),
                    decoration: const MoeInputDecoration(
                      hintText: '{\n  "persona": "鲁迅"\n}',
                    ),
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(onPressed: _save, child: const Text('保存')),
          ),
        ],
      ),
    );
  }
}

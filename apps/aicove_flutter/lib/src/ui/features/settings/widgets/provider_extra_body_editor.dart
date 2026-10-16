import 'package:flutter/material.dart';

import '../../../../core/api/providers/provider_extra_body.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

/// 编辑渠道额外请求参数；返回 null 表示取消，空表表示清空。
Future<Map<String, dynamic>?> showProviderExtraBodyEditor(
  BuildContext context,
  Map<String, dynamic> customConfig,
) => showJsonObjectEditor(
  context,
  title: '额外请求参数',
  description: '填写 JSON 对象，每次聊天请求都会合并到请求体顶层，同名字段以这里为准。留空即清除。',
  hintText: '{\n  "persona": "鲁迅"\n}',
  initialText: formatProviderExtraBody(customConfig),
  parse: parseProviderExtraBody,
  fieldKey: const ValueKey('provider-extra-body-json'),
);

/// 通用 JSON 对象编辑弹窗：[parse] 抛 [FormatException] 时显示错误并留在弹窗内。
Future<Map<String, dynamic>?> showJsonObjectEditor(
  BuildContext context, {
  required String title,
  required String description,
  required String hintText,
  required String initialText,
  required Map<String, dynamic> Function(String source) parse,
  Key? fieldKey,
}) => showDialog<Map<String, dynamic>>(
  context: context,
  builder: (context) => Dialog(
    backgroundColor: Colors.transparent,
    insetPadding: const EdgeInsets.all(16),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: JsonObjectEditor(
        title: title,
        description: description,
        hintText: hintText,
        initialText: initialText,
        parse: parse,
        fieldKey: fieldKey,
      ),
    ),
  ),
);

class JsonObjectEditor extends StatefulWidget {
  const JsonObjectEditor({
    super.key,
    required this.title,
    required this.description,
    required this.hintText,
    required this.initialText,
    required this.parse,
    this.fieldKey,
  });

  final String title;
  final String description;
  final String hintText;
  final String initialText;
  final Map<String, dynamic> Function(String source) parse;
  final Key? fieldKey;

  @override
  State<JsonObjectEditor> createState() => _JsonObjectEditorState();
}

class _JsonObjectEditorState extends State<JsonObjectEditor> {
  late final TextEditingController _json = TextEditingController(
    text: widget.initialText,
  );
  String? _error;

  @override
  void dispose() {
    _json.dispose();
    super.dispose();
  }

  void _save() {
    try {
      Navigator.of(context).pop(widget.parse(_json.text));
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
                    widget.title,
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
                    widget.description,
                    style: TextStyle(fontSize: 13, color: colors.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: widget.fieldKey,
                    controller: _json,
                    minLines: 4,
                    maxLines: 12,
                    style: const TextStyle(fontFamily: 'monospace'),
                    decoration: MoeInputDecoration(hintText: widget.hintText),
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
            child: MoePrimaryButton(
              label: '保存',
              width: double.infinity,
              onPressed: _save,
            ),
          ),
        ],
      ),
    );
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../../core/api/image_providers/comfyui_workflow.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

Future<Map<String, dynamic>?> showComfyUIWorkflowEditor(
  BuildContext context,
  Map<String, dynamic> config,
) => showDialog<Map<String, dynamic>>(
  context: context,
  builder: (context) => Dialog(
    backgroundColor: Colors.transparent,
    insetPadding: const EdgeInsets.all(16),
    child: SizedBox(
      width: 640,
      height: MediaQuery.sizeOf(context).height * .85,
      child: ComfyUIWorkflowEditor(config: config),
    ),
  ),
);

class ComfyUIWorkflowEditor extends StatefulWidget {
  const ComfyUIWorkflowEditor({super.key, required this.config});
  final Map<String, dynamic> config;

  @override
  State<ComfyUIWorkflowEditor> createState() => _ComfyUIWorkflowEditorState();
}

class _ComfyUIWorkflowEditorState extends State<ComfyUIWorkflowEditor> {
  late final TextEditingController _json;
  late Map<String, String> _bindings;
  Map<String, dynamic>? _graph;
  String _output = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    final raw = widget.config[ComfyUIWorkflow.workflowKey];
    _json = TextEditingController(
      text: raw == null
          ? ''
          : raw is String
          ? raw
          : const JsonEncoder.withIndent('  ').convert(raw),
    );
    _bindings = Map<String, String>.from(
      widget.config[ComfyUIWorkflow.bindingsKey] as Map? ?? {},
    );
    _output = widget.config[ComfyUIWorkflow.outputKey]?.toString() ?? '';
    if (_json.text.isNotEmpty) _parse();
  }

  @override
  void dispose() {
    _json.dispose();
    super.dispose();
  }

  void _parse() {
    try {
      final graph = ComfyUIWorkflow.parse(_json.text);
      final choices = ComfyUIWorkflow.inputChoices(graph);
      setState(() {
        _graph = graph;
        _bindings.removeWhere((key, value) => !choices.containsKey(value));
        if (!graph.containsKey(_output)) _output = '';
        _error = null;
      });
    } catch (error) {
      setState(() {
        _graph = null;
        _error = error.toString();
      });
    }
  }

  Future<void> _import() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
      if (result == null || !mounted) return;
      final file = result.files.single;
      final bytes = file.bytes ?? await File(file.path!).readAsBytes();
      if (!mounted) return;
      _json.text = utf8.decode(bytes);
      _bindings.clear();
      _output = '';
      _parse();
    } catch (error) {
      if (mounted) setState(() => _error = '导入失败：$error');
    }
  }

  void _save() {
    _parse();
    if (_graph == null) return;
    final config = <String, dynamic>{
      ComfyUIWorkflow.workflowKey: _graph,
      ComfyUIWorkflow.bindingsKey: _bindings,
      ComfyUIWorkflow.outputKey: _output,
    };
    try {
      ComfyUIWorkflow.validate(config);
      Navigator.of(context).pop(config);
    } catch (error) {
      setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final choices = _graph == null
        ? <String, String>{}
        : ComfyUIWorkflow.inputChoices(_graph!);
    return MoeFloatingSurface(
      radius: 20,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'ComfyUI 工作流',
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
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '从 ComfyUI 导出 API 格式 JSON。选择接收提示词的节点输入；未绑定的参数沿用工作流原值。',
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: _import,
                        icon: const Icon(Icons.file_open_outlined),
                        label: const Text('导入 JSON 文件'),
                      ),
                      TextButton(
                        onPressed: _parse,
                        child: const Text('解析粘贴内容'),
                      ),
                    ],
                  ),
                  TextField(
                    key: const ValueKey('comfy-workflow-json'),
                    controller: _json,
                    minLines: 4,
                    maxLines: 7,
                    decoration: const MoeInputDecoration(
                      hintText: '在此粘贴 API 工作流 JSON',
                    ),
                    onChanged: (_) {
                      if (_graph != null) setState(() => _graph = null);
                    },
                  ),
                  if (_graph != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      '参数绑定 · ${_graph!.length} 个节点',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    for (final field in ComfyUIWorkflow.fieldLabels.entries)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: _dropdown(
                          label: field.value,
                          value: _bindings[field.key] ?? '',
                          choices: choices,
                          emptyLabel: field.key == 'prompt'
                              ? '请选择（已使用 %prompt% 可留空）'
                              : '沿用工作流',
                          onChanged: (value) => setState(() {
                            if (value.isEmpty) {
                              _bindings.remove(field.key);
                            } else {
                              _bindings[field.key] = value;
                            }
                          }),
                        ),
                      ),
                    const SizedBox(height: 12),
                    _dropdown(
                      label: '图片输出节点',
                      value: _output,
                      choices: {
                        for (final entry in _graph!.entries)
                          entry.key:
                              '${entry.key} · ${(entry.value as Map)['class_type']}',
                      },
                      emptyLabel: '自动读取保存的图片',
                      onChanged: (value) => setState(() => _output = value),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '也支持 %prompt%、%negative_prompt%、%seed%、%width%、%height% 等占位符。工作流需包含保存图片的输出节点。',
                    ),
                  ],
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
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
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: _save, child: const Text('保存工作流')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dropdown({
    required String label,
    required String value,
    required Map<String, String> choices,
    required String emptyLabel,
    required ValueChanged<String> onChanged,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label),
      DropdownButtonFormField<String>(
        initialValue: value,
        key: ValueKey('$label:$value:${choices.keys.join(',')}'),
        isExpanded: true,
        decoration: const MoeInputDecoration(isDense: true),
        items: [
          DropdownMenuItem(
            value: '',
            child: Text(emptyLabel, overflow: TextOverflow.ellipsis),
          ),
          for (final entry in choices.entries)
            DropdownMenuItem(
              value: entry.key,
              child: Text(entry.value, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (value) => onChanged(value ?? ''),
      ),
    ],
  );
}

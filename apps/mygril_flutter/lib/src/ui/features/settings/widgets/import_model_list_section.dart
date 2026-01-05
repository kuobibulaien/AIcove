/// ImportModelListSection - 模型列表选择组件
/// 
/// 从 import_model_dialog.dart 提取，处理模型列表的加载和选择。
/// 
/// 更新记录：
/// - 2025-12-31: 从 import_model_dialog.dart 提取
library;

import 'package:flutter/material.dart';

import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/index.dart';

/// 模型列表选择组件
class ModelListSection extends StatelessWidget {
  final List<String> loadedModels;
  final Set<String> selectedModels;
  final bool loading;
  final String? error;
  final bool canPreview;
  final TextEditingController defaultModelController;
  final VoidCallback onLoadModels;
  final void Function(String model, bool selected) onModelToggle;
  final VoidCallback onSelectAll;
  final VoidCallback onDeselectAll;

  const ModelListSection({
    super.key,
    required this.loadedModels,
    required this.selectedModels,
    required this.loading,
    required this.error,
    required this.canPreview,
    required this.defaultModelController,
    required this.onLoadModels,
    required this.onModelToggle,
    required this.onSelectAll,
    required this.onDeselectAll,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 加载模型按钮
        Row(
          children: [
            MoePrimaryButton(
              label: loading ? '加载中…' : '加载模型列表',
              icon: Icons.cloud_download_outlined,
              enabled: canPreview && !loading,
              onPressed: onLoadModels,
            ),
            const SizedBox(width: 12),
            if (!canPreview)
              Expanded(
                child: Text(
                  '当前模式暂不支持自动加载，请手动填写默认模型。',
                  style: TextStyle(color: colors.muted, fontSize: 12),
                ),
              )
            else if (loadedModels.isNotEmpty)
              Text(
                '共 ${loadedModels.length} 个模型',
                style: TextStyle(color: colors.muted, fontSize: 12),
              ),
          ],
        ),

        // 错误提示
        if (error != null) ...[
          const SizedBox(height: 8),
          Text(
            error!,
            style: const TextStyle(color: Colors.redAccent, fontSize: 12),
          ),
        ],

        // 默认模型输入（无模型列表时）
        if (!canPreview || loadedModels.isEmpty) ...[
          const SizedBox(height: 8),
          TextFormField(
            controller: defaultModelController,
            decoration: const InputDecoration(
              labelText: '默认模型名称',
              hintText: '例如：gpt-4o',
            ),
            validator: (value) {
              if ((!canPreview || loadedModels.isEmpty) && (value == null || value.trim().isEmpty)) {
                return '请填写默认模型名称';
              }
              return null;
            },
          ),
        ],

        // 模型选择列表
        if (loadedModels.isNotEmpty) ...[
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '选择要显示的模型',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: colors.text,
                ),
              ),
              Row(
                children: [
                  TextButton(
                    onPressed: onSelectAll,
                    child: const Text('全选'),
                  ),
                  TextButton(
                    onPressed: onDeselectAll,
                    child: const Text('全不选'),
                  ),
                ],
              ),
            ],
          ),
          SizedBox(
            height: 200,
            child: Scrollbar(
              child: ListView.builder(
                itemCount: loadedModels.length,
                itemBuilder: (context, index) {
                  final model = loadedModels[index];
                  final checked = selectedModels.contains(model);
                  return CheckboxListTile(
                    dense: true,
                    value: checked,
                    title: Text(model),
                    onChanged: (value) => onModelToggle(model, value ?? false),
                  );
                },
              ),
            ),
          ),
        ],
      ],
    );
  }
}

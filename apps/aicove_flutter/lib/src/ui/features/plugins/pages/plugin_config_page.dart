import 'package:flutter/material.dart';
import '../../../../features/plugins/domain/index.dart';
import '../../../shared/widgets/index.dart';

/// 插件配置页面（通用）
/// 根据插件的 metadata.configSchema 自动生成配置界面
class PluginConfigPage extends StatefulWidget {
  final Plugin plugin;
  final ValueChanged<Map<String, dynamic>> onConfigChanged;

  const PluginConfigPage({
    super.key,
    required this.plugin,
    required this.onConfigChanged,
  });

  @override
  State<PluginConfigPage> createState() => _PluginConfigPageState();
}

class _PluginConfigPageState extends State<PluginConfigPage> {
  late Map<String, dynamic> _currentConfig;

  @override
  void initState() {
    super.initState();
    _currentConfig = Map.from(widget.plugin.getConfig());
  }

  void _handleConfigChange(Map<String, dynamic> newConfig) {
    setState(() {
      _currentConfig = newConfig;
    });
  }

  Future<void> _saveConfig() async {
    try {
      // 验证所有字段
      bool allValid = true;
      for (final entry in widget.plugin.metadata.configSchema.entries) {
        final value = _currentConfig[entry.key];
        if (!entry.value.validate(value)) {
          allValid = false;
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('配置项 "${entry.value.label}" 验证失败')),
            );
          }
          return;
        }
      }

      if (allValid) {
        widget.onConfigChanged(_currentConfig);
        
        // 触发插件配置变更回调
        await widget.plugin.onConfigChanged(_currentConfig);
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('配置已保存')),
          );
          Navigator.pop(context);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasSchema = widget.plugin.metadata.configSchema.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.plugin.name} 设置'),
        actions: [
          if (hasSchema)
            IconButton(
              icon: const Icon(Icons.check),
              onPressed: _saveConfig,
            ),
        ],
      ),
      body: hasSchema
          ? ConfigFormWidget(
              schema: widget.plugin.metadata.configSchema,
              values: _currentConfig,
              onChanged: _handleConfigChange,
            )
          : const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.settings_outlined, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('此插件无可配置项', style: TextStyle(color: Colors.grey)),
                ],
              ),
            ),
    );
  }
}

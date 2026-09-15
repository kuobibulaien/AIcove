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

class _PluginConfigPageState extends State<PluginConfigPage>
    with MoeAutoSaveState<PluginConfigPage> {
  late Map<String, dynamic> _currentConfig;

  @override
  void initState() {
    super.initState();
    _currentConfig = Map.from(widget.plugin.getConfig());
    autoSave.configure(
      save: _saveConfig,
      snapshot: () => moeAutoSaveSignature(_currentConfig),
    );
  }

  void _handleConfigChange(Map<String, dynamic> newConfig) {
    setState(() {
      _currentConfig = newConfig;
    });
  }

  Future<void> _saveConfig() async {
    final config = Map<String, dynamic>.from(_currentConfig);
    for (final entry in widget.plugin.metadata.configSchema.entries) {
      if (!entry.value.validate(config[entry.key])) {
        throw FormatException('请检查${entry.value.label}');
      }
    }
    await widget.plugin.onConfigChanged(config);
    widget.onConfigChanged(config);
  }

  @override
  Widget build(BuildContext context) {
    final hasSchema = widget.plugin.metadata.configSchema.isNotEmpty;

    return autoSavePage(
      MoePageScaffold(
        appBar: AppBar(title: Text('${widget.plugin.name} 设置')),
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
      ),
    );
  }
}

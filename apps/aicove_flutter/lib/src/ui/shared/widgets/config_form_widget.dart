import 'package:flutter/material.dart';
import '../../../features/plugins/domain/index.dart';
import '../../theme/tokens.dart';
import 'index.dart';

/// 配置表单组件
/// 根据插件的 configSchema 自动渲染表单控件
class ConfigFormWidget extends StatefulWidget {
  /// 配置模板
  final Map<String, ConfigField> schema;

  /// 当前配置值
  final Map<String, dynamic> values;

  /// 配置变更回调
  final ValueChanged<Map<String, dynamic>> onChanged;

  const ConfigFormWidget({
    super.key,
    required this.schema,
    required this.values,
    required this.onChanged,
  });

  @override
  State<ConfigFormWidget> createState() => _ConfigFormWidgetState();
}

class _ConfigFormWidgetState extends State<ConfigFormWidget> {
  late Map<String, dynamic> _currentValues;
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, String?> _errors = {};

  @override
  void initState() {
    super.initState();
    _currentValues = Map.from(widget.values);
    _initControllers();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _initControllers() {
    for (final entry in widget.schema.entries) {
      final key = entry.key;
      final field = entry.value;

      if (field.type == ConfigFieldType.string ||
          field.type == ConfigFieldType.integer ||
          field.type == ConfigFieldType.number) {
        final value = _currentValues[key] ?? field.defaultValue ?? '';
        _controllers[key] = TextEditingController(text: value.toString());
      }
    }
  }

  void _updateValue(String key, dynamic value) {
    setState(() {
      _currentValues[key] = value;
      _errors[key] = null;
    });
    widget.onChanged(_currentValues);
  }

  bool _validateField(String key, ConfigField field, dynamic value) {
    if (!field.validate(value)) {
      setState(() {
        _errors[key] = field.validationError ?? '输入不合法';
      });
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: widget.schema.entries.map((entry) {
        final key = entry.key;
        final field = entry.value;
        return _buildFieldWidget(key, field);
      }).toList(),
    );
  }

  Widget _buildFieldWidget(String key, ConfigField field) {
    switch (field.type) {
      case ConfigFieldType.boolean:
        return _buildBooleanField(key, field);
      case ConfigFieldType.string:
        return _buildStringField(key, field);
      case ConfigFieldType.integer:
        return _buildIntegerField(key, field);
      case ConfigFieldType.number:
        return _buildNumberField(key, field);
      case ConfigFieldType.select:
        return _buildSelectField(key, field);
      case ConfigFieldType.multiSelect:
        return _buildMultiSelectField(key, field);
    }
  }

  Widget _buildBooleanField(String key, ConfigField field) {
    final value = _currentValues[key] ?? field.defaultValue ?? false;
    
    return MoeSettingsRow(
      icon: Icons.toggle_on,
      label: field.label,
      subtitle: field.description,
      trailingType: MoeSettingsRowTrailing.custom,
      trailing: MoeSwitch(
        value: value as bool,
        onChanged: (newValue) => _updateValue(key, newValue),
      ),
    );
  }

  Widget _buildStringField(String key, ConfigField field) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: MoeTextField(
        controller: _controllers[key]!,
        label: field.label,
        hint: field.description,
        errorText: _errors[key],
        onChanged: (value) {
          if (_validateField(key, field, value)) {
            _updateValue(key, value);
          }
        },
      ),
    );
  }

  Widget _buildIntegerField(String key, ConfigField field) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: MoeTextField(
        controller: _controllers[key]!,
        label: field.label,
        hint: field.description,
        errorText: _errors[key],
        keyboardType: TextInputType.number,
        onChanged: (value) {
          final intValue = int.tryParse(value);
          if (intValue != null && _validateField(key, field, intValue)) {
            _updateValue(key, intValue);
          }
        },
      ),
    );
  }

  Widget _buildNumberField(String key, ConfigField field) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: MoeTextField(
        controller: _controllers[key]!,
        label: field.label,
        hint: field.description,
        errorText: _errors[key],
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onChanged: (value) {
          final numValue = double.tryParse(value);
          if (numValue != null && _validateField(key, field, numValue)) {
            _updateValue(key, numValue);
          }
        },
      ),
    );
  }

  Widget _buildSelectField(String key, ConfigField field) {
    final value = _currentValues[key] ?? field.defaultValue;
    
    return MoeSettingsRow(
      icon: Icons.arrow_drop_down,
      label: field.label,
      subtitle: field.description,
      trailingType: MoeSettingsRowTrailing.custom,
      trailing: DropdownButton<String>(
        value: value?.toString(),
        items: field.options!.map((option) {
          return DropdownMenuItem(
            value: option,
            child: Text(option),
          );
        }).toList(),
        onChanged: (newValue) {
          if (newValue != null) {
            _updateValue(key, newValue);
          }
        },
      ),
    );
  }

  Widget _buildMultiSelectField(String key, ConfigField field) {
    final selectedValues = (_currentValues[key] as List?) ?? [];
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 8),
          child: Text(
            field.label,
            style: const TextStyle(fontSize: 16, fontWeight: MoeFontWeights.emphasis),
          ),
        ),
        if (field.description != null)
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 12),
            child: Text(
              field.description!,
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ),
        ...field.options!.map((option) {
          final isSelected = selectedValues.contains(option);
          return MoeCheckbox(
            value: isSelected,
            label: option,
            onChanged: (checked) {
              final newList = List.from(selectedValues);
              if (checked == true) {
                newList.add(option);
              } else {
                newList.remove(option);
              }
              _updateValue(key, newList);
            },
          );
        }),
        const SizedBox(height: 16),
      ],
    );
  }
}

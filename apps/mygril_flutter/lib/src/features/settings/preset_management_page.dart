/// 角色预设管理页面
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/data_image.dart';
import 'character_preset.dart';
import 'preset_store.dart';

class PresetManagementPage extends StatefulWidget {
  const PresetManagementPage({super.key});

  @override
  State<PresetManagementPage> createState() => _PresetManagementPageState();
}

class _PresetManagementPageState extends State<PresetManagementPage> {
  final PresetStore _store = PresetStore();
  List<CharacterPreset> _presets = [];
  bool _loading = true;
  String? _error;

  // 内置头像选项
  final List<String> _builtInAvatars = [
    'assets/characters/Arona.webp',
    'assets/characters/Aru.webp',
    'assets/characters/Hoshino.webp',
    'assets/characters/Shiroko.webp',
    'assets/characters/Hina.webp',
  ];

  @override
  void initState() {
    super.initState();
    _loadPresets();
  }

  Future<void> _loadPresets() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final presets = await _store.loadPresets();
      setState(() {
        _presets = presets;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _deletePreset(String id) async {
    try {
      await _store.deletePreset(id);
      await _loadPresets();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('预设已删除'), duration: Duration(seconds: 1)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败: $e'), duration: const Duration(seconds: 1)),
      );
    }
  }

  Future<void> _showPresetDialog({CharacterPreset? preset}) async {
    final result = await showDialog<CharacterPreset>(
      context: context,
      builder: (context) => _PresetEditDialog(
        store: _store,
        preset: preset,
        builtInAvatars: _builtInAvatars,
      ),
    );

    if (result != null) {
      await _loadPresets();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        backgroundColor: colors.surface,
        foregroundColor: colors.text,
        elevation: 0,
        title: const Text('角色预设管理'),
        actions: [
          TextButton.icon(
            onPressed: () => _showPresetDialog(),
            icon: const Icon(Icons.add),
            label: const Text('新建预设'),
          ),
          const SizedBox(width: 8),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(borderWidth),
          child: Container(height: borderWidth, color: colors.divider),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final colors = context.moeColors;

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('加载失败: $_error'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _loadPresets,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    if (_presets.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.folder_open, size: 64, color: colors.textSecondary),
            const SizedBox(height: 16),
            Text('暂无预设', style: TextStyle(color: colors.textSecondary)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _showPresetDialog(),
              icon: const Icon(Icons.add),
              label: const Text('创建第一个预设'),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _presets.length,
      itemBuilder: (context, index) {
        final preset = _presets[index];
        return _PresetCard(
          preset: preset,
          onEdit: () => _showPresetDialog(preset: preset),
          onDelete: () => _deletePreset(preset.id),
        );
      },
    );
  }
}

class _PresetCard extends StatelessWidget {
  final CharacterPreset preset;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _PresetCard({
    required this.preset,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            // 头像预览
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.all(radiusBubble),
                color: isDark ? colors.panel : Colors.grey[200],
              ),
              clipBehavior: Clip.antiAlias,
              child: _buildAvatar(context),
            ),
            const SizedBox(width: 16),
            // 信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    preset.name,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '角色：${preset.displayName}',
                    style: TextStyle(
                      fontSize: 14,
                      color: colors.textSecondary,
                    ),
                  ),
                  if (preset.organization != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      '组织：${preset.organization}',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // 操作按钮
            IconButton(
              onPressed: onEdit,
              icon: const Icon(Icons.edit_outlined),
              tooltip: '编辑',
            ),
            IconButton(
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('确认删除'),
                    content: Text('确定要删除预设"${preset.name}"吗？'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('删除'),
                      ),
                    ],
                  ),
                );
                if (confirm == true) onDelete();
              },
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatar(BuildContext context) {
    if (preset.characterImage != null) {
      return Image.asset(
        preset.characterImage!,
        fit: BoxFit.cover,
        errorBuilder: (context, __, ___) => _buildFallback(context),
      );
    }
    if (preset.avatarUrl != null) {
      final dataBytes = decodeDataImage(preset.avatarUrl!);
      if (dataBytes != null) {
        return Image.memory(dataBytes, fit: BoxFit.cover);
      }
    }
    return _buildFallback(context);
  }

  Widget _buildFallback(BuildContext context) {
    final colors = context.moeColors;
    final letter = preset.displayName.isNotEmpty ? preset.displayName[0] : '预';
    return Center(
      child: Text(
        letter,
        style: TextStyle(fontSize: 24, color: colors.textSecondary),
      ),
    );
  }
}

class _PresetEditDialog extends StatefulWidget {
  final CharacterPreset? preset;
  final List<String> builtInAvatars;
  final PresetStore store;

  const _PresetEditDialog({
    this.preset,
    required this.builtInAvatars,
    required this.store,
  });

  @override
  State<_PresetEditDialog> createState() => _PresetEditDialogState();
}

class _PresetEditDialogState extends State<_PresetEditDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _displayNameCtrl;
  late final TextEditingController _orgCtrl;
  late final TextEditingController _promptCtrl;

  String? _selectedBuiltInAvatar;
  String? _customAvatarData;
  Uint8List? _customAvatarBytes;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.preset?.name ?? '');
    _displayNameCtrl = TextEditingController(text: widget.preset?.displayName ?? '');
    _orgCtrl = TextEditingController(text: widget.preset?.organization ?? '');
    _promptCtrl = TextEditingController(text: widget.preset?.personaPrompt ?? '');

    // 初始化头像选择
    if (widget.preset != null) {
      if (widget.preset!.characterImage != null &&
          widget.builtInAvatars.contains(widget.preset!.characterImage)) {
        _selectedBuiltInAvatar = widget.preset!.characterImage;
      } else if (widget.preset!.avatarUrl != null) {
        _customAvatarData = widget.preset!.avatarUrl;
      }
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _displayNameCtrl.dispose();
    _orgCtrl.dispose();
    _promptCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickCustomAvatar() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    if (file.bytes == null) return;

    setState(() {
      _customAvatarBytes = file.bytes;
      _customAvatarData = buildDataImage(file.bytes!, fileName: file.name);
      _selectedBuiltInAvatar = null; // 清除内置选择
    });
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty || _displayNameCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('预设名称和角色名称不能为空'), duration: Duration(seconds: 1)),
      );
      return;
    }

    setState(() => _saving = true);

    try {
      final avatarUrl = _customAvatarData;
      final characterImage = _selectedBuiltInAvatar;

      if (widget.preset == null) {
        // 创建
        await widget.store.createPreset(
          name: _nameCtrl.text.trim(),
          displayName: _displayNameCtrl.text.trim(),
          avatarUrl: avatarUrl,
          characterImage: characterImage,
          organization: _orgCtrl.text.trim().isEmpty ? null : _orgCtrl.text.trim(),
          personaPrompt: _promptCtrl.text.trim(),
        );
      } else {
        // 更新
        await widget.store.updatePreset(
          widget.preset!.id,
          name: _nameCtrl.text.trim(),
          displayName: _displayNameCtrl.text.trim(),
          avatarUrl: avatarUrl,
          characterImage: characterImage,
          organization: _orgCtrl.text.trim().isEmpty ? null : _orgCtrl.text.trim(),
          personaPrompt: _promptCtrl.text.trim(),
        );
      }

      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $e'), duration: const Duration(seconds: 1)),
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return AlertDialog(
      title: Text(widget.preset == null ? '新建预设' : '编辑预设'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 500,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(labelText: '预设名称'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _displayNameCtrl,
                decoration: const InputDecoration(labelText: '角色名称'),
              ),
              const SizedBox(height: 16),
              Text('选择内置头像', style: TextStyle(fontSize: 14, color: colors.textSecondary)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: widget.builtInAvatars.map((avatar) {
                  final isSelected = _selectedBuiltInAvatar == avatar;
                  return GestureDetector(
                    onTap: () {
                      setState(() {
                        _selectedBuiltInAvatar = avatar;
                        _customAvatarData = null;
                        _customAvatarBytes = null;
                      });
                    },
                    child: Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.all(radiusBubble),
                        border: Border.all(
                          color: isSelected ? colors.primary : colors.divider,
                          width: isSelected ? 3 : 1,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Image.asset(avatar, fit: BoxFit.cover),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: _pickCustomAvatar,
                    icon: const Icon(Icons.upload_file),
                    label: const Text('上传自定义头像'),
                  ),
                  if (_customAvatarBytes != null) ...[
                    const SizedBox(width: 12),
                    Container(
                      width: 40,
                      height: 40,
                      decoration:
                          BoxDecoration(borderRadius: BorderRadius.all(radiusBubble)),
                      clipBehavior: Clip.antiAlias,
                      child: Image.memory(_customAvatarBytes!, fit: BoxFit.cover),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _orgCtrl,
                decoration: const InputDecoration(labelText: '所属组织（可选）'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _promptCtrl,
                maxLines: 4,
                decoration: const InputDecoration(labelText: '人设提示词'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('保存'),
        ),
      ],
    );
  }
}

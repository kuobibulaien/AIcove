import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/image_crop_dialog.dart';
import '../../domain/conversation.dart';
import '../../../../core/utils/data_image.dart';
import '../widgets/contact_edit_dialog.dart';
import '../../providers2.dart';
import '../../../settings/character_preset.dart';
import '../../../settings/preset_store.dart';

/// 编辑角色信息的独立页面
/// 目标：支持修改名称、头像（可本地选择并裁剪预览）、人设提示词
class ContactEditPage extends ConsumerStatefulWidget {
  final Conversation conversation;
  final bool isNew; // 是否为新建模式
  const ContactEditPage({super.key, required this.conversation, this.isNew = false});

  @override
  ConsumerState<ContactEditPage> createState() => _ContactEditPageState();
}

class _ContactEditPageState extends ConsumerState<ContactEditPage> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _avatarCtrl;
  late final TextEditingController _addressCtrl;
  late final TextEditingController _personaCtrl;

  Uint8List? _croppedBytes; // 裁剪完成后的图片

  // 预设相关
  final PresetStore _presetStore = PresetStore();
  List<CharacterPreset> _presets = [];
  CharacterPreset? _selectedPreset;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.conversation.displayName);
    _avatarCtrl = TextEditingController(text: widget.conversation.avatarUrl ?? '');
    _addressCtrl = TextEditingController(text: widget.conversation.addressUser ?? '');
    _personaCtrl = TextEditingController(text: widget.conversation.personaPrompt);
    
    // 加载预设列表（仅在新建模式）
    if (widget.isNew) {
      _loadPresets();
    }
  }

  Future<void> _loadPresets() async {
    try {
      final presets = await _presetStore.loadPresets();
      setState(() => _presets = presets);
    } catch (e) {
      // 加载失败不影响使用
    }
  }

  Future<void> _applyPreset(CharacterPreset preset) async {
    setState(() {
      _selectedPreset = preset;
      _nameCtrl.text = preset.displayName;
      _addressCtrl.text = preset.addressUser ?? '';
      _personaCtrl.text = preset.personaPrompt;
    });

    // 如果有头像或立绘，加载为 _croppedBytes
    String? imageSource;
    if (preset.avatarUrl != null) {
      imageSource = preset.avatarUrl;
    } else if (preset.characterImage != null) {
      imageSource = preset.characterImage;
    }

    if (imageSource != null) {
      // 尝试解码为字节数组
      final bytes = decodeDataImage(imageSource);
      if (bytes != null) {
        setState(() {
          _croppedBytes = bytes;
          _avatarCtrl.text = imageSource!;
        });
      } else {
        // 如果不是 data URL，保存到 avatarCtrl 以便显示
        setState(() {
          _avatarCtrl.text = imageSource!;
          _croppedBytes = null;
        });
      }
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _avatarCtrl.dispose();
    _addressCtrl.dispose();
    _personaCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Scaffold(
      backgroundColor: moeSurface,
      appBar: AppBar(
        backgroundColor: colors.headerColor,
        foregroundColor: colors.headerContentColor,
        elevation: 0,
        title: Text(widget.isNew ? '新建角色' : '编辑角色信息'),
        actions: [
          TextButton(
            onPressed: _onSaveAsPreset,
            child: const Text('保存为新预设'),
          ),
          TextButton(
            onPressed: _onSave,
            child: const Text('保存'),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(borderWidth),
          child: Container(height: borderWidth, color: moeDividerColor),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 预设选择（仅在新建模式显示）
          if (widget.isNew && _presets.isNotEmpty) ...[
            const Text(
              '选择预设',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: _showPresetSelector,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                decoration: BoxDecoration(
                  border: Border.all(color: moeBorderLight, width: borderWidth),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _selectedPreset?.name ?? '选择一个预设快速填充（可选）',
                        style: TextStyle(
                          fontSize: 15,
                          color: _selectedPreset != null ? moeText : moeMuted,
                        ),
                      ),
                    ),
                    const Icon(Icons.arrow_drop_down, color: moeMuted),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Divider(),
            const SizedBox(height: 16),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _buildAvatarPreview(),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _nameCtrl,
                      decoration: const InputDecoration(labelText: '角色名称'),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        FilledButton.icon(
                          onPressed: _pickLocalImage,
                          icon: const Icon(Icons.image_outlined),
                          label: const Text('从本地选择'),
                        ),
                        const SizedBox(width: 12),
                        if (_croppedBytes != null)
                          Text(
                            '已裁剪',
                            style: TextStyle(color: Colors.green[700]),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),
          TextField(
            controller: _addressCtrl,
            decoration: const InputDecoration(
              labelText: '对我的称呼（可选）',
              hintText: '例如：老师、先生、主人',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _personaCtrl,
            maxLines: 5,
            decoration: const InputDecoration(labelText: '人设提示词'),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatarPreview() {
    final double size = 72;

    Widget content;
    if (_croppedBytes != null) {
      content = Image.memory(_croppedBytes!, fit: BoxFit.cover);
    } else {
      final dataBytes = decodeDataImage(_avatarCtrl.text);
      if (dataBytes != null) {
        content = Image.memory(dataBytes, fit: BoxFit.cover);
      } else if (_avatarCtrl.text.startsWith('http')) {
        content = Image.network(_avatarCtrl.text, fit: BoxFit.cover);
      } else if (_avatarCtrl.text.startsWith('assets/')) {
        // 支持 assets 资源路径
        content = Image.asset(
          _avatarCtrl.text,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildFallbackLetter(),
        );
      } else {
        content = _buildFallbackLetter();
      }
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.all(radiusBubble),
        color: Colors.white,
      ),
      clipBehavior: Clip.antiAlias,
      child: content,
    );
  }

  Widget _buildFallbackLetter() {
    final title = _nameCtrl.text.trim();
    final letter = title.isNotEmpty ? title[0] : '新';
    return Center(
      child: Text(
        letter,
        style: const TextStyle(fontSize: 26, color: moeTextSecondary, fontWeight: FontWeight.w600),
      ),
    );
  }

  Future<void> _pickLocalImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true, // 需要字节以便裁剪
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    if (file.bytes == null) return;

    // 打开裁剪弹窗
    if (!mounted) return;
    final croppedBytes = await Navigator.of(context).push<Uint8List>(
      PageRouteBuilder(
        opaque: false,
        barrierDismissible: false,
        barrierColor: Colors.black,
        transitionDuration: const Duration(milliseconds: 250),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (context, animation, secondaryAnimation) => ImageCropDialog(
          imageBytes: file.bytes!,
          fileName: file.name,
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          // 组合淡入和轻微缩放效果
          final fadeAnimation = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOut,
          );
          final scaleAnimation = Tween<double>(
            begin: 0.95,
            end: 1.0,
          ).animate(CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          ));
          
          return FadeTransition(
            opacity: fadeAnimation,
            child: ScaleTransition(
              scale: scaleAnimation,
              child: child,
            ),
          );
        },
      ),
    );

    if (croppedBytes != null) {
      _updateAvatarData(croppedBytes, fileName: file.name);
    }
  }

  Future<void> _onSave() async {
    final name = _nameCtrl.text.trim().isEmpty ? '新角色' : _nameCtrl.text.trim();
    final avatar = _avatarCtrl.text.trim().isEmpty ? null : _avatarCtrl.text.trim();
    final address = _addressCtrl.text.trim().isEmpty ? null : _addressCtrl.text.trim();
    final persona = _personaCtrl.text.trim();

    if (widget.isNew) {
      // 新建模式：创建新对话并应用信息
      final notifier = ref.read(conversationsProvider.notifier);
      final id = await notifier.createNew();

      await notifier.applyContactEdit(
        id,
        displayName: name,
        avatarUrl: avatar,
        characterImage: null,
        organization: null,
        addressUser: address,
        personaPrompt: persona,
      );

      ref.read(activeConversationIdProvider.notifier).state = id;
      if (!mounted) return;
      context.go('/chat/$id');
    } else {
      // 编辑模式：返回结果
      Navigator.of(context).pop<ContactEditResult>(
        ContactEditResult(
          displayName: name,
          avatarUrl: avatar,
          characterImage: widget.conversation.characterImage,
          organization: widget.conversation.organization,
          addressUser: address,
          personaPrompt: persona,
        ),
      );
    }
  }

  void _updateAvatarData(Uint8List bytes, {String? fileName}) {
    final dataUrl = buildDataImage(bytes, fileName: fileName);
    setState(() {
      _croppedBytes = bytes;
      _avatarCtrl.text = dataUrl;
    });
  }

  Future<void> _onSaveAsPreset() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先填写角色名称')),
      );
      return;
    }

    // 弹出对话框让用户输入预设名称
    final presetName = await showDialog<String>(
      context: context,
      builder: (context) {
        final controller = TextEditingController(text: name);
        return AlertDialog(
          title: const Text('保存为新预设'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: '预设名称',
              hintText: '为这个预设起个名字',
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );

    if (presetName == null || presetName.isEmpty) return;

    try {
      // 创建新预设
      await _presetStore.createPreset(
        name: presetName,
        displayName: _nameCtrl.text.trim(),
        avatarUrl: _avatarCtrl.text.trim().isEmpty ? null : _avatarCtrl.text.trim(),
        characterImage: null,
        organization: null,
        personaPrompt: _personaCtrl.text.trim(),
      );

      // 刷新预设列表
      await _loadPresets();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('预设 "$presetName" 已保存')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$e')),
      );
    }
  }

  Future<void> _showPresetSelector() async {
    final selected = await showModalBottomSheet<CharacterPreset?>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.6,
          ),
          decoration: const BoxDecoration(
            color: moeSurface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 标题栏
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '选择预设',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: moeText,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: moeMuted),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              const Divider(height: 0, thickness: borderWidth, color: moeDividerColor),
              // 预设列表
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    // "不使用预设"选项
                    ListTile(
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.all(radiusBubble),
                          color: moeSurfaceAlt,
                        ),
                        child: const Icon(Icons.close, color: moeMuted, size: 20),
                      ),
                      title: const Text('不使用预设'),
                      selected: _selectedPreset == null,
                      selectedTileColor: moeSurfaceAlt,
                      onTap: () => Navigator.pop(context, null),
                    ),
                    const Divider(height: 0, thickness: borderWidth, color: moeDividerColor),
                    // 预设选项
                    ..._presets.map((preset) {
                      return Column(
                        children: [
                          ListTile(
                            leading: _buildPresetAvatar(preset),
                            title: Text(preset.name),
                            subtitle: preset.displayName != preset.name
                                ? Text(
                                    preset.displayName,
                                    style: const TextStyle(fontSize: 12, color: moeMuted),
                                  )
                                : null,
                            selected: _selectedPreset == preset,
                            selectedTileColor: moeSurfaceAlt,
                            onTap: () => Navigator.pop(context, preset),
                          ),
                          const Divider(height: 0, thickness: borderWidth, color: moeDividerColor),
                        ],
                      );
                    }),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );

    // 处理选择结果
    if (selected != null) {
      await _applyPreset(selected);
    } else if (selected == null && _selectedPreset != null) {
      // 用户选择了"不使用预设"
      setState(() => _selectedPreset = null);
    }
  }

  Widget _buildPresetAvatar(CharacterPreset preset) {
    // 尝试解码 avatarUrl
    final avatarBytes = decodeDataImage(preset.avatarUrl);
    if (avatarBytes != null) {
      return Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.all(radiusBubble),
          color: Colors.white,
        ),
        clipBehavior: Clip.antiAlias,
        child: Image.memory(avatarBytes, fit: BoxFit.cover),
      );
    }

    // 如果是网络URL
    final avatar = preset.avatarUrl;
    if (avatar != null && avatar.startsWith('http')) {
      return Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.all(radiusBubble),
          color: Colors.white,
        ),
        clipBehavior: Clip.antiAlias,
        child: Image.network(avatar, fit: BoxFit.cover),
      );
    }

    // 如果是本地asset路径
    if (avatar != null && avatar.trim().isNotEmpty) {
      return Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.all(radiusBubble),
          color: Colors.white,
        ),
        clipBehavior: Clip.antiAlias,
        child: Image.asset(
          avatar,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildPresetFallbackAvatar(preset),
        ),
      );
    }

    // 尝试使用 characterImage 字段
    final charBytes = decodeDataImage(preset.characterImage);
    if (charBytes != null) {
      return Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.all(radiusBubble),
          color: Colors.white,
        ),
        clipBehavior: Clip.antiAlias,
        child: Image.memory(charBytes, fit: BoxFit.cover),
      );
    }

    final char = preset.characterImage;
    if (char != null && char.trim().isNotEmpty) {
      return Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.all(radiusBubble),
          color: Colors.white,
        ),
        clipBehavior: Clip.antiAlias,
        child: Image.asset(
          char,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildPresetFallbackAvatar(preset),
        ),
      );
    }

    // 最后使用字母占位符
    return _buildPresetFallbackAvatar(preset);
  }

  Widget _buildPresetFallbackAvatar(CharacterPreset preset) {
    final letter = preset.displayName.isNotEmpty ? preset.displayName[0] : preset.name[0];
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.all(radiusBubble),
        color: moeSurfaceAlt,
      ),
      child: Center(
        child: Text(
          letter,
          style: const TextStyle(fontSize: 18, color: moePrimary, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}




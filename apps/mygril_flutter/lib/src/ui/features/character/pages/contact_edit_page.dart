import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../features/chat/domain/conversation.dart';
import '../../../../core/utils/data_image.dart';
import '../../../../features/chat/presentation/widgets/contact_edit_dialog.dart';
import '../../../../features/chat/providers2.dart';

/// 编辑模式枚举
/// - create: 新建角色（保存后直接进入对话）
/// - editConversation: 编辑对话中的角色（可保存为新角色卡）
/// - editTemplate: 编辑模板/收藏的角色卡（可直接保存或保存为新角色卡）
enum EditMode {
  create,           // 新建角色
  editConversation, // 编辑对话中的角色
  editTemplate,     // 编辑模板（我的角色卡）
}

/// 新建/编辑角色卡页面
/// 
/// 布局结构：
/// - 上半部分（左右分栏）：
///   - 左侧：头像 + 参考图（上下排列，中间有"使用一致图像"开关）
///   - 右侧：角色名称、简介
/// - 下半部分（纵向排列）：
///   - 人格设定
///   - 称呼设置（自称 + 对我的称呼，填写后以 JSON 附加到提示词）
///   - 音色设置（上传 mp3/wav 音频）
/// 
/// 更新记录：
/// - 2026-01-06: 添加 EditMode 枚举，支持"保存为新角色卡"功能
/// - 2025-12-08: 重构布局，新增自称、音色设置
class ContactEditPage extends ConsumerStatefulWidget {
  final Conversation conversation;
  final EditMode editMode;
  
  /// 兼容旧 API：isNew=true 等价于 editMode=create
  const ContactEditPage({
    super.key,
    required this.conversation,
    @Deprecated('Use editMode instead') bool isNew = false,
    EditMode? editMode,
  }) : editMode = editMode ?? (isNew ? EditMode.create : EditMode.editConversation);

  @override
  ConsumerState<ContactEditPage> createState() => _ContactEditPageState();
}

class _ContactEditPageState extends ConsumerState<ContactEditPage> {
  // 基本信息
  late final TextEditingController _nameCtrl;
  late final TextEditingController _descCtrl; // 简介
  late final TextEditingController _personaCtrl; // 人格提示词
  
  // 称呼设置
  late final TextEditingController _selfAddressCtrl; // 角色自称
  late final TextEditingController _addressUserCtrl; // 对我的称呼
  
  // 图像数据
  late final TextEditingController _avatarCtrl;
  late final TextEditingController _refImageCtrl;
  Uint8List? _avatarBytes;
  bool _useSameImage = true; // 使用一致图像
  
  // 音色设置
  String? _voiceFileName;
  Uint8List? _voiceFileBytes;

  @override
  void initState() {
    super.initState();
    final conv = widget.conversation;
    
    _nameCtrl = TextEditingController(text: conv.displayName);
    _descCtrl = TextEditingController(text: conv.description ?? '');
    _personaCtrl = TextEditingController(text: conv.personaPrompt);
    _selfAddressCtrl = TextEditingController(text: conv.selfAddress ?? '');
    _addressUserCtrl = TextEditingController(text: conv.addressUser ?? '');
    _avatarCtrl = TextEditingController(text: conv.avatarUrl ?? '');
    _refImageCtrl = TextEditingController(text: conv.characterImage ?? '');
    
    // 初始化图像字节数据
    if (_avatarCtrl.text.isNotEmpty) {
      _avatarBytes = decodeDataImage(_avatarCtrl.text);
    }
    // 判断是否使用一致图像
    if (widget.editMode == EditMode.create) {
      _useSameImage = true;
    } else {
      _useSameImage = _refImageCtrl.text.isEmpty || _refImageCtrl.text == _avatarCtrl.text;
    }
    
    // 初始化音色文件
    if (conv.voiceFile != null && conv.voiceFile!.isNotEmpty) {
      _voiceFileName = '已设置音色';
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _personaCtrl.dispose();
    _selfAddressCtrl.dispose();
    _addressUserCtrl.dispose();
    _avatarCtrl.dispose();
    _refImageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    // 移除 Hero，改用自定义展开路由实现"原地展开"动画
    return Scaffold(
      // 暗色适配：背景跟随主题
      backgroundColor: colors.surface,
      appBar: AppBar(
        backgroundColor: colors.headerColor,
        foregroundColor: colors.headerContentColor,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(_getTitle()),
        actions: _buildActions(colors),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(borderWidth),
          child: Container(height: borderWidth, color: colors.divider),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ========== 形象图片（竖版海报）==========
            Center(
              child: GestureDetector(
                onTap: () => _pickImage(isAvatar: true),
                child: Container(
                  width: 160,
                  height: 220,
                  decoration: MoeG2Decoration(
                    radius: 12,
                    color: colors.surfaceAlt.withValues(alpha: 0.3),
                    border: Border.all(
                      color: colors.borderLight,
                      width: 1,
                    ),
                  ),
                  child: _avatarBytes != null
                      ? MoeG2ClipRRect(
                          radius: 11,
                          child: Image.memory(_avatarBytes!, fit: BoxFit.cover),
                        )
                      : Center(
                          child: Icon(Icons.add, size: 36, color: colors.primary),
                        ),
                ),
              ),
            ),
            
            const SizedBox(height: 24),

            // ========== 人设（人格设定）==========
            _buildSettingRow(
              icon: Icons.auto_awesome,
              title: '人设 *',
              trailing: const SizedBox.shrink(),
            ),
            const SizedBox(height: 8),
            
            // 昵称
            Text('昵称 *', style: TextStyle(fontSize: 12, color: colors.muted)),
            const SizedBox(height: 6),
            _buildTextField(_nameCtrl, '给角色起个名字'),
            const SizedBox(height: 16),
            
            // 简介
            Text('简介', style: TextStyle(fontSize: 12, color: colors.muted)),
            const SizedBox(height: 6),
            _buildTextField(_descCtrl, '一句话介绍角色（可选）', maxLines: 2),
            const SizedBox(height: 16),
            
            // 人格提示词
            Text('人格设定 *', style: TextStyle(fontSize: 12, color: colors.muted)),
            const SizedBox(height: 6),
            _buildTextField(_personaCtrl, '详细描述角色的性格、说话方式、背景故事...', maxLines: 6),
            const SizedBox(height: 4),
            Text('💡 越详细越生动', style: TextStyle(fontSize: 11, color: colors.muted)),
            
            const SizedBox(height: 20),
            _buildDivider(),

            // ========== 称呼设置 ==========
            _buildSettingRow(
              icon: Icons.chat_bubble_outline,
              title: '称呼设置',
              trailing: const SizedBox.shrink(),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('自称', style: TextStyle(fontSize: 11, color: colors.muted)),
                      const SizedBox(height: 4),
                      _buildTextField(_selfAddressCtrl, '如：我、本小姐'),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('对我的称呼', style: TextStyle(fontSize: 11, color: colors.muted)),
                      const SizedBox(height: 4),
                      _buildTextField(_addressUserCtrl, '如：主人、先生'),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),
            _buildDivider(),

            // ========== 声音设置（可选，TTS 联动）==========
            _buildSettingRow(
              icon: Icons.record_voice_over,
              title: '声音',
              trailing: GestureDetector(
                onTap: _pickVoiceFile,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _voiceFileName ?? '添加音色',
                      style: TextStyle(color: colors.muted, fontSize: 14),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.chevron_right, color: colors.muted, size: 20),
                  ],
                ),
              ),
            ),
            Text('可选，上传 mp3/wav 音频用于 TTS 语音合成', style: TextStyle(fontSize: 11, color: colors.muted)),

            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  // ========== 辅助组件 ==========

  Widget _buildSettingRow({
    required IconData icon,
    required String title,
    required Widget trailing,
  }) {
    final colors = context.moeColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: colors.primary),
          const SizedBox(width: 8),
          Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: colors.text)),
          const Spacer(),
          trailing,
        ],
      ),
    );
  }

  Widget _buildTextField(TextEditingController controller, String hint, {int maxLines = 1}) {
    final colors = context.moeColors;
    return MoeTextField(
      controller: controller,
      maxLines: maxLines,
      minLines: maxLines > 1 ? 2 : 1,
      hint: hint,
      fillColor: colors.surfaceAlt.withValues(alpha: 0.3),
      borderWidth: 0,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    );
  }

  Widget _buildDivider() {
    return Divider(height: 1, color: context.moeColors.borderLight.withValues(alpha: 0.3));
  }

  Future<void> _pickImage({required bool isAvatar}) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    if (file.bytes == null) return;

    Uint8List? finalBytes = file.bytes;

    // 头像需要裁剪
    if (isAvatar && mounted) {
      final croppedBytes = await Navigator.of(context).push<Uint8List>(
        PageRouteBuilder(
          opaque: false,
          barrierDismissible: false,
          barrierColor: Colors.black,
          transitionDuration: kAnim,
          reverseTransitionDuration: kAnim,
          pageBuilder: (context, animation, secondaryAnimation) => ImageCropDialog(
            imageBytes: file.bytes!,
            fileName: file.name,
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final fadeAnimation = CurvedAnimation(parent: animation, curve: Curves.easeOut);
            final scaleAnimation = Tween<double>(begin: 0.95, end: 1.0).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            );
            return FadeTransition(
              opacity: fadeAnimation,
              child: ScaleTransition(scale: scaleAnimation, child: child),
            );
          },
        ),
      );
      if (croppedBytes != null) {
        finalBytes = croppedBytes;
      } else {
        return;
      }
    }

    if (finalBytes != null) {
      final dataUrl = buildDataImage(finalBytes, fileName: file.name);
      setState(() {
        if (isAvatar) {
          _avatarBytes = finalBytes;
          _avatarCtrl.text = dataUrl;
          if (_useSameImage) {
            _refImageCtrl.text = dataUrl;
          }
        } else {
          _refImageCtrl.text = dataUrl;
        }
      });
    }
  }

  Future<void> _pickVoiceFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'wav', 'm4a', 'aac'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    setState(() {
      _voiceFileName = file.name;
      _voiceFileBytes = file.bytes;
    });
  }

  String _buildAddressJson() {
    final selfAddr = _selfAddressCtrl.text.trim();
    final userAddr = _addressUserCtrl.text.trim();
    if (selfAddr.isEmpty && userAddr.isEmpty) return '';
    
    final map = <String, String>{};
    if (selfAddr.isNotEmpty) map['self_address'] = selfAddr;
    if (userAddr.isNotEmpty) map['user_address'] = userAddr;
    return '\n[称呼设置]: ${map.toString()}';
  }

  // ========== 标题和保存按钮逻辑 ==========

  String _getTitle() {
    switch (widget.editMode) {
      case EditMode.create:
        return '新建角色卡';
      case EditMode.editConversation:
        return '编辑角色信息';
      case EditMode.editTemplate:
        return '编辑模板';
    }
  }

  List<Widget> _buildActions(MoeColors colors) {
    switch (widget.editMode) {
      case EditMode.create:
        // 新建模式：只有"保存"
        return [
          TextButton(
            onPressed: _onSave,
            child: Text('保存', style: TextStyle(color: colors.headerContentColor)),
          ),
        ];
      case EditMode.editConversation:
        // 编辑对话角色："保存" + 更多菜单（保存为新角色卡）
        return [
          TextButton(
            onPressed: _onSave,
            child: Text('保存', style: TextStyle(color: colors.headerContentColor)),
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, color: colors.headerContentColor),
            onSelected: (value) {
              if (value == 'saveAsNew') _onSaveAsNewTemplate();
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'saveAsNew',
                child: Row(
                  children: [
                    Icon(Icons.bookmark_add_outlined, size: 20),
                    SizedBox(width: 12),
                    Text('保存为新角色卡'),
                  ],
                ),
              ),
            ],
          ),
        ];
      case EditMode.editTemplate:
        // 编辑模板："保存" + "保存为新角色卡"（两个按钮）
        return [
          TextButton(
            onPressed: _onSaveAsNewTemplate,
            child: Text('另存为', style: TextStyle(color: colors.headerContentColor.withValues(alpha: 0.8))),
          ),
          TextButton(
            onPressed: _onSaveTemplate,
            child: Text('保存', style: TextStyle(color: colors.headerContentColor)),
          ),
        ];
    }
  }

  /// 构建编辑结果数据
  ContactEditResult _buildEditResult() {
    final name = _nameCtrl.text.trim();
    final avatar = _avatarCtrl.text.trim().isEmpty ? null : _avatarCtrl.text.trim();
    final characterImage = _useSameImage
        ? avatar
        : (_refImageCtrl.text.trim().isEmpty ? null : _refImageCtrl.text.trim());
    String persona = _personaCtrl.text.trim();
    final addressJson = _buildAddressJson();
    if (addressJson.isNotEmpty) {
      persona = persona + addressJson;
    }
    final addressUser = _addressUserCtrl.text.trim().isEmpty ? null : _addressUserCtrl.text.trim();
    final description = _descCtrl.text.trim().isEmpty ? null : _descCtrl.text.trim();

    return ContactEditResult(
      displayName: name,
      avatarUrl: avatar,
      characterImage: characterImage,
      addressUser: addressUser,
      description: description,
      personaPrompt: persona,
    );
  }

  /// 验证表单
  bool _validateForm() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      MoeToast.error(context, '请输入角色名称');
      return false;
    }
    return true;
  }

  /// 保存（覆盖当前角色）
  Future<void> _onSave() async {
    if (!_validateForm()) return;
    final result = _buildEditResult();

    if (widget.editMode == EditMode.create) {
      // 新建模式：创建新角色并进入对话
      final notifier = ref.read(conversationsProvider.notifier);
      final id = await notifier.createNew();

      await notifier.applyContactEdit(
        id,
        displayName: result.displayName,
        avatarUrl: result.avatarUrl,
        characterImage: result.characterImage,
        addressUser: result.addressUser,
        description: result.description,
        personaPrompt: result.personaPrompt,
      );

      ref.read(activeConversationIdProvider.notifier).state = id;
      if (!mounted) return;
      context.go('/chat/$id');
    } else {
      // 编辑模式：返回编辑结果
      Navigator.of(context).pop<ContactEditResult>(result);
    }
  }

  /// 保存模板（直接更新模板角色卡）
  Future<void> _onSaveTemplate() async {
    if (!_validateForm()) return;
    final result = _buildEditResult();

    final notifier = ref.read(conversationsProvider.notifier);
    await notifier.applyContactEdit(
      widget.conversation.id,
      displayName: result.displayName,
      avatarUrl: result.avatarUrl,
      characterImage: result.characterImage,
      addressUser: result.addressUser,
      description: result.description,
      personaPrompt: result.personaPrompt,
    );

    if (!mounted) return;
    MoeToast.success(context, '模板已保存');
    Navigator.of(context).pop();
  }

  /// 保存为新角色卡（创建新角色并标记为收藏）
  Future<void> _onSaveAsNewTemplate() async {
    if (!_validateForm()) return;
    final result = _buildEditResult();

    final notifier = ref.read(conversationsProvider.notifier);
    final id = await notifier.createNew();

    await notifier.applyContactEdit(
      id,
      displayName: result.displayName,
      avatarUrl: result.avatarUrl,
      characterImage: result.characterImage,
      addressUser: result.addressUser,
      description: result.description,
      personaPrompt: result.personaPrompt,
    );

    // 标记为收藏（加入"我的角色卡"）
    await notifier.updateConversationSettings(id, isFavorite: true);

    if (!mounted) return;
    MoeToast.success(context, '已保存到我的角色卡');
    Navigator.of(context).pop();
  }
}

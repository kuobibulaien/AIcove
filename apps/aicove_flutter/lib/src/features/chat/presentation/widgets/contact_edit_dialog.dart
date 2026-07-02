import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../../ui/theme/tokens.dart';
import 'package:aicove_flutter/src/core/utils/data_image.dart';
import 'package:aicove_flutter/src/ui/shared/effects/smooth_clip.dart';

import '../../domain/conversation.dart';
import '../../domain/persona_prompt_codec.dart';
import '../../../../ui/shared/widgets/meotalk_dialog.dart';

class ContactEditResult {
  final String displayName;
  final String? avatarUrl;
  final String? characterImage;
  final String? chatBackgroundImage;
  final String? selfAddress; // 角色自称
  final String? addressUser; // 角色对"我"的称呼
  final String? voiceFile; // 绑定音色（预设ID或音频数据）
  final String? description; // 角色简介（给用户看的介绍）
  final String personaPrompt; // 人格提示词（给 AI 用的设定）
  final List<String>? enabledPlugins; // 允许插件列表，null=允许全部
  final String? recipeId; // SillyTavern preset recipe ID
  final bool clearAvatarUrl;
  final bool clearCharacterImage;
  final bool clearChatBackgroundImage;
  final bool clearSelfAddress;
  final bool clearAddressUser;
  final bool clearVoiceFile;
  final bool clearDescription;
  final bool clearEnabledPlugins;
  final bool clearRecipeId;

  const ContactEditResult({
    required this.displayName,
    this.avatarUrl,
    this.characterImage,
    this.chatBackgroundImage,
    this.selfAddress,
    this.addressUser,
    this.voiceFile,
    this.description,
    required this.personaPrompt,
    this.enabledPlugins,
    this.recipeId,
    this.clearAvatarUrl = false,
    this.clearCharacterImage = false,
    this.clearChatBackgroundImage = false,
    this.clearSelfAddress = false,
    this.clearAddressUser = false,
    this.clearVoiceFile = false,
    this.clearDescription = false,
    this.clearEnabledPlugins = false,
    this.clearRecipeId = false,
  });
}

Future<ContactEditResult?> showContactEditDialog({
  required BuildContext context,
  required Conversation conversation,
}) {
  final nameCtrl = TextEditingController(text: conversation.displayName);
  final addressCtrl =
      TextEditingController(text: conversation.addressUser ?? '');
  final personaParts = PersonaPromptCodec.parse(conversation.personaPrompt);
  final personaCtrl = TextEditingController(text: personaParts.userPrompt);

  String? avatarData = conversation.avatarUrl;
  String? characterData = conversation.characterImage;
  Uint8List? avatarBytes = decodeDataImage(avatarData);
  Uint8List? characterBytes = decodeDataImage(characterData);

  return showDialog<ContactEditResult>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          Future<void> pickAvatar() async {
            final result = await FilePicker.platform.pickFiles(
              type: FileType.image,
              withData: true,
            );
            if (result == null || result.files.isEmpty) return;
            final file = result.files.first;
            if (file.bytes == null) return;
            setState(() {
              avatarBytes = file.bytes;
              avatarData = buildDataImage(file.bytes!, fileName: file.name);
            });
          }

          Future<void> pickCharacterImage() async {
            final result = await FilePicker.platform.pickFiles(
              type: FileType.image,
              withData: true,
            );
            if (result == null || result.files.isEmpty) return;
            final file = result.files.first;
            if (file.bytes == null) return;
            setState(() {
              characterBytes = file.bytes;
              characterData = buildDataImage(file.bytes!, fileName: file.name);
            });
          }

          Widget avatarPreview() {
            if (avatarBytes != null) {
              return MoeG2ClipRRect(
                radius: radiusBubble.x,
                child: Image.memory(avatarBytes!,
                    width: 72, height: 72, fit: BoxFit.cover),
              );
            }
            if (avatarData != null && avatarData!.trim().isNotEmpty) {
              return MoeG2ClipRRect(
                radius: radiusBubble.x,
                child: Image.asset(
                  avatarData!,
                  width: 72,
                  height: 72,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _fallbackLetter(nameCtrl.text),
                ),
              );
            }
            return MoeG2ClipRRect(
              radius: radiusBubble.x,
              child: _fallbackLetter(nameCtrl.text),
            );
          }

          Widget characterPreview() {
            if (characterBytes != null) {
              return Image.memory(characterBytes!,
                  width: 140, height: 180, fit: BoxFit.cover);
            }
            if (characterData != null && characterData!.trim().isNotEmpty) {
              return Image.asset(
                characterData!,
                width: 140,
                height: 180,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox(),
              );
            }
            return Container(
              width: 140,
              height: 180,
              alignment: Alignment.center,
              decoration: MoeG2Decoration(
                radius: 12,
                color: Colors.grey.shade200,
              ),
              child: const Icon(Icons.image_not_supported_outlined,
                  size: 42, color: Colors.grey),
            );
          }

          return MeoTalkDialog(
            title: '编辑联系人',
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: '显示名称'),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      avatarPreview(),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FilledButton.icon(
                            onPressed: pickAvatar,
                            icon: const Icon(Icons.image),
                            label: const Text('选择头像'),
                          ),
                          if (avatarData != null)
                            TextButton(
                              onPressed: () => setState(() {
                                avatarData = null;
                                avatarBytes = null;
                              }),
                              child: const Text('清除'),
                            ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text('角色立绘', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  characterPreview(),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: pickCharacterImage,
                        icon: const Icon(Icons.photo_library_outlined),
                        label: const Text('选择立绘'),
                      ),
                      const SizedBox(width: 8),
                      if (characterData != null)
                        TextButton(
                          onPressed: () => setState(() {
                            characterData = null;
                            characterBytes = null;
                          }),
                          child: const Text('清除'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: addressCtrl,
                    decoration: const InputDecoration(
                      labelText: '对我的称呼（可选）',
                      hintText: '例如：老师、先生、主人',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: personaCtrl,
                    maxLines: 3,
                    decoration: const InputDecoration(labelText: '人物提示词（可选）'),
                  ),
                ],
              ),
            ),
            cancelText: '取消',
            confirmText: '保存',
            onCancel: () => Navigator.of(context).pop(),
            onConfirm: () {
              final name = nameCtrl.text.trim().isEmpty
                  ? conversation.displayName
                  : nameCtrl.text.trim();
              final address = addressCtrl.text.trim().isEmpty
                  ? null
                  : addressCtrl.text.trim();
              final persona = personaCtrl.text.trim();
              Navigator.of(context).pop(ContactEditResult(
                displayName: name,
                avatarUrl: avatarData,
                characterImage: characterData,
                addressUser: address,
                personaPrompt: PersonaPromptCodec.compose(
                  userPrompt: persona,
                  customDrawingPrompt: personaParts.customDrawingPrompt,
                  drawingToolPresetName: personaParts.drawingToolPresetName,
                  drawingArtistPresetName: personaParts.drawingArtistPresetName,
                ),
              ));
            },
          );
        },
      );
    },
  );
}

Widget _fallbackLetter(String name) {
  final letter = name.isNotEmpty ? name[0] : '新';
  return Container(
    width: 72,
    height: 72,
    decoration: MoeG2Decoration(
      radius: 10,
      color: const Color(0xFFF0F0F0),
    ),
    alignment: Alignment.center,
    child: Text(
      letter,
      style: const TextStyle(
          fontSize: 24,
          color: Color(0xFF999999),
          fontWeight: MoeFontWeights.emphasis),
    ),
  );
}
